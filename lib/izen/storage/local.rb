# frozen_string_literal: true

require "fileutils"

require_relative "service"

module Izen
  module Storage
    # Stores files in a directory on disk, sharded by a generated key, and
    # serves them through the app's static middleware.
    #
    #   development:
    #     service: local
    #     path: storage/uploads   # relative to Izen.root
    #     url: /uploads           # public path the files are served from
    class Local < Service
      attr_reader :path, :url_base

      def initialize(settings, root:)
        super
        @path     = File.expand_path(option(settings, "path", DEFAULT_PATH), root)
        @url_base = normalize_url(option(settings, "url", DEFAULT_URL))
      end

      def store(upload, key: nil)
        key ||= Key.generate(Upload.filename(upload))
        key   = Key.normalize(key)

        destination = absolute(key)
        FileUtils.mkdir_p(File.dirname(destination))
        Upload.copy(upload, destination)
        key
      end

      def read(key)
        File.binread(absolute(key))
      end

      def delete(key)
        File.delete(absolute(key))
        true
      rescue Errno::ENOENT
        false
      end

      def exist?(key)
        File.file?(absolute(key))
      end

      def url(key, **_options)
        "#{@url_base}/#{Key.normalize(key)}"
      end

      # The directory the static middleware should serve, and the URL prefix it
      # is mounted at. `public_url` is nil for a service whose `url` is an
      # absolute http(s) address (a CDN), where the app does not serve files.
      def public_dir
        @path
      end

      def public_url
        @url_base.start_with?("/") ? @url_base : nil
      end

      private

      def option(settings, key, fallback)
        value = settings[key] || settings[key.to_sym]
        value.nil? || value.to_s.empty? ? fallback : value.to_s
      end

      def normalize_url(url)
        url = url.to_s.sub(%r{/+\z}, "")
        url.match?(%r{\Ahttps?://}) ? url : "/#{url.sub(%r{\A/+}, "")}"
      end

      # A key must not escape the storage directory even if a caller hands in
      # an absolute-looking or dot-containing path.
      def absolute(key)
        path = File.expand_path(Key.normalize(key), @path)
        unless path == @path || path.start_with?("#{@path}/")
          raise Error, "storage key escapes the storage root"
        end

        path
      end
    end
  end
end
