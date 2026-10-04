# frozen_string_literal: true

require_relative "config"

module Izen
  # File storage for uploads, selected per environment by config/storage.yml —
  # the same way config/database.yaml selects the SQLite file.
  #
  #   development:
  #     service: local
  #     path: storage/uploads   # relative to Izen.root
  #     url: /uploads           # public path the files are served from
  #
  # Two services ship: `local` (writes under `path`, served by
  # Izen::Application at `url`) and `s3`/`s3_compatible` (any S3-compatible
  # object store). Each backend is a Storage::Service subclass in its own file
  # under lib/izen/storage/ and is registered in SERVICES; callers keep using
  # the same module API:
  #
  #   key = Izen::Storage.store(params["avatar"])  # => "2026/10/ab12….png"
  #   Izen::Storage.url(key)                       # => "/uploads/2026/10/ab12….png"
  #   Izen::Storage.read(key)
  #   Izen::Storage.delete(key)
  #
  # `store` accepts whatever shape a request carries a file in: a Rack
  # multipart hash (`{ filename:, tempfile: }`), an uploaded-file object, a
  # File/IO, or a path on disk. It returns the storage key; persist the key and
  # derive the URL from it, never the other way around.
  module Storage
    class Error < StandardError; end
    class MissingService < Error; end

    # Defaults for the bundled local service; also used when config/storage.yml
    # is absent, so storage works out of the box.
    DEFAULT_PATH     = "storage/uploads"
    DEFAULT_URL      = "/uploads"
    DEFAULT_SETTINGS = {
      "service" => "local",
      "path"    => DEFAULT_PATH,
      "url"     => DEFAULT_URL
    }.freeze

    class << self
      # Writes +upload+ and returns its key. Pass +key+ to choose the path
      # yourself (e.g. "avatars/#{user.id}.png"); otherwise a random, sharded
      # key is generated from the upload's filename.
      def store(upload, key: nil)
        service.store(upload, key: key)
      end

      # Reads a stored file back as a binary String.
      def read(key)
        service.read(key)
      end

      # Deletes a stored file. Returns true when a file was removed, false when
      # it was already gone.
      def delete(key)
        service.delete(key)
      end

      def exist?(key)
        service.exist?(key)
      end

      # Public path/URL for a stored key.
      def url(key, **options)
        service.url(key, **options)
      end

      # The active service instance, built from config/storage.yml.
      def service
        @service ||= build_service
      end

      # The service settings for the current APP_ENV.
      def config
        @config ||= load_config
      end

      def env
        ENV.fetch("APP_ENV", "development")
      end

      # config/storage.yml (or .yaml) under the application root, or nil when
      # the app has not created one yet.
      def config_path
        %w[config/storage.yml config/storage.yaml]
          .map { |path| File.join(Izen.root, path) }
          .find { |path| File.file?(path) }
      end

      # The directory a local service serves from, or nil when the active
      # service is not backed by a directory on this machine.
      def public_dir
        service.respond_to?(:public_dir) ? service.public_dir : nil
      end

      # The URL prefix a local service is mounted at, or nil when it is not
      # served by this app (e.g. files live on a CDN).
      def public_url
        service.respond_to?(:public_url) ? service.public_url : nil
      end

      # Drops the memoized config and service. Used by tests and by apps that
      # change APP_ENV or Izen.root at runtime.
      def reset!
        @config  = nil
        @service = nil
      end
      alias reload! reset!

      private

      def build_service
        settings = config
        name     = (settings["service"] || settings[:service] || "local").to_s
        klass    = SERVICES[name]
        unless klass
          raise MissingService,
            "unknown storage service #{name.inspect} (known: #{SERVICES.keys.join(", ")})"
        end

        klass.new(settings, root: Izen.root)
      end

      def load_config
        path = config_path
        return DEFAULT_SETTINGS unless path

        parsed  = Izen::Config.load_yaml(path)
        parsed  = {} unless parsed.is_a?(Hash)
        current = parsed[env] || parsed["default"]
        current.is_a?(Hash) ? current : DEFAULT_SETTINGS
      rescue Config::Error => e
        raise Error, e.message
      end
    end
  end
end

# The pieces live in lib/izen/storage/: the base Service, the upload/key
# helpers, and one file per backend. They reopen Izen::Storage, so this file
# must define the module first.
require_relative "storage/service"
require_relative "storage/upload"
require_relative "storage/key"
require_relative "storage/local"
require_relative "storage/s3"
require_relative "storage/static"

module Izen
  module Storage
    # Registered backends, looked up by the `service:` setting. Add another
    # Service subclass in lib/izen/storage/ and register it here.
    SERVICES = {
      "local"         => Local,
      "s3"            => S3,
      "s3_compatible" => S3
    }.freeze
  end
end
