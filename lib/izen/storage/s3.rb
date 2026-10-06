# frozen_string_literal: true

require_relative "service"

module Izen
  module Storage
    # Stores files in any S3-compatible object store — AWS S3, Cloudflare R2,
    # MinIO, ... — through the aws-sdk-s3 gem (loaded lazily, so it is only a
    # dependency of apps that actually use this service).
    #
    #   production:
    #     service: s3
    #     bucket: my-bucket
    #     region: auto                          # R2; defaults to "auto"
    #     endpoint: https://<id>.r2.cloudflarestorage.com
    #     prefix: uploads                       # optional key prefix
    #     public_url: https://cdn.example.com   # optional; enables plain URLs
    #
    # Credentials and the bucket may also come from the standard S3_* env vars
    # (S3_BUCKET, S3_REGION, S3_ENDPOINT, S3_ACCESS_KEY_ID, S3_SECRET_ACCESS_KEY,
    # S3_PREFIX, S3_PUBLIC_URL), which is the recommended place for secrets.
    class S3 < Service
      DEFAULT_REGION  = "auto"
      DEFAULT_EXPIRES = 3600

      attr_reader :bucket, :region, :endpoint, :prefix

      def initialize(settings, root:)
        super
        @bucket     = required(settings, "bucket", "S3_BUCKET")
        @region     = option(settings, "region", "S3_REGION") || DEFAULT_REGION
        @endpoint   = option(settings, "endpoint", "S3_ENDPOINT")
        @access_key = option(settings, "access_key_id", "S3_ACCESS_KEY_ID")
        @secret_key = option(settings, "secret_access_key", "S3_SECRET_ACCESS_KEY")
        @public_url = option(settings, "public_url", "S3_PUBLIC_URL")
        @prefix     = option(settings, "prefix", "S3_PREFIX").to_s.sub(%r{\A/+}, "").sub(%r{/+\z}, "")
        @expires_in = (option(settings, "expires_in", "S3_URL_EXPIRES_IN") || DEFAULT_EXPIRES).to_i
        @path_style = truthy?(option(settings, "force_path_style", "S3_FORCE_PATH_STYLE"))
        @client     = settings[:client] || settings["client"]
      end

      def store(upload, key: nil)
        key ||= Key.generate(Upload.filename(upload))
        key   = Key.normalize(key)

        io, close = Upload.io_for(upload)
        io.rewind if io.respond_to?(:rewind)
        client.put_object(
          bucket:       @bucket,
          key:          object_key(key),
          body:         io,
          content_type: Upload.content_type(upload)
        )
        key
      ensure
        io.close if close && io
      end

      def read(key)
        body = client.get_object(bucket: @bucket, key: object_key(key)).body
        body.respond_to?(:read) ? body.read : body.to_s
      end

      def delete(key)
        client.delete_object(bucket: @bucket, key: object_key(key))
        true
      rescue StandardError => e
        raise unless not_found?(e)

        false
      end

      def exist?(key)
        client.head_object(bucket: @bucket, key: object_key(key))
        true
      rescue StandardError => e
        raise unless not_found?(e)

        false
      end

      # Lists objects under the optional +prefix+, following continuation
      # tokens so a bucket larger than one page is fully enumerated. Keys are
      # returned with the configured storage `prefix` stripped, matching what
      # `store` returns. `size` is nil when a client does not report it.
      def list(prefix: nil)
        full_prefix = [ @prefix, prefix ].map(&:to_s).reject(&:empty?).join("/")
        entries     = []
        token       = nil

        loop do
          params                      = { bucket: @bucket }
          params[:prefix]             = full_prefix unless full_prefix.empty?
          params[:continuation_token] = token if token
          response                    = client.list_objects_v2(**params)

          Array(response.contents).each do |object|
            key  = object.respond_to?(:key) ? object.key : object.to_s
            size = object.respond_to?(:size) ? object.size : nil
            entries << { key: strip_prefix(key), size: size }
          end

          token = response.respond_to?(:next_continuation_token) ? response.next_continuation_token : nil
          break unless response.respond_to?(:is_truncated) && response.is_truncated && token
        end

        entries
      end

      # A permanent URL when `public_url` is configured (public bucket or CDN),
      # otherwise a short-lived presigned URL — the right default for a private
      # bucket such as R2.
      def url(key, expires_in: nil)
        object = object_key(key)
        return "#{@public_url.sub(%r{/+\z}, "")}/#{object}" unless @public_url.to_s.empty?

        presigned_url(object, (expires_in || @expires_in).to_i)
      end

      private

      def option(settings, key, env_key)
        value = settings[key] || settings[key.to_sym]
        value = ENV[env_key] if value.nil? || value.to_s.empty?
        value.nil? || value.to_s.empty? ? nil : value.to_s
      end

      def required(settings, key, env_key)
        value = option(settings, key, env_key)
        if value.nil?
          raise Error, "storage service s3 requires #{key} (set it in config/storage.yml or #{env_key})"
        end

        value
      end

      def truthy?(value)
        %w[1 true yes on].include?(value.to_s.downcase)
      end

      def object_key(key)
        key = Key.normalize(key)
        @prefix.empty? ? key : "#{@prefix}/#{key}"
      end

      # Inverse of #object_key: strips the configured prefix so callers see the
      # same key they passed to `store`.
      def strip_prefix(key)
        return key if @prefix.empty?
        return key unless key.start_with?("#{@prefix}/")

        key.delete_prefix("#{@prefix}/")
      end

      def client
        @client ||= build_client
      end

      def build_client
        require "aws-sdk-s3"
        Aws::S3::Client.new(**client_options)
      rescue LoadError
        raise Error, "the s3 storage service requires the aws-sdk-s3 gem"
      end

      def client_options
        options                    = {
          region:            @region,
          access_key_id:     @access_key,
          secret_access_key: @secret_key
        }
        options[:endpoint]         = @endpoint unless @endpoint.nil?
        options[:force_path_style] = true if @path_style
        options.reject { |_, value| value.nil? }
      end

      # An injected client (tests) may implement presigning directly; the real
      # aws-sdk client does not, so fall back to Aws::S3::Presigner.
      def presigned_url(object, expires)
        if @client.respond_to?(:presigned_url)
          return @client.presigned_url(@bucket, object, expires)
        end

        require "aws-sdk-s3"
        Aws::S3::Presigner.new(client: client)
                         .presigned_url(:get_object, bucket: @bucket, key: object, expires_in: expires)
      rescue LoadError
        raise Error, "the s3 storage service requires the aws-sdk-s3 gem"
      end

      # Not-found shapes differ across clients (aws-sdk, the native shim); a
      # 404 status is the common denominator.
      def not_found?(error)
        name = error.class.name.to_s
        name.include?("NotFound") || name.include?("NoSuchKey") ||
          (error.respond_to?(:status_code) && error.status_code == 404)
      end
    end
  end
end
