# frozen_string_literal: true

module Izen
  module Storage
    # Interface every storage backend implements. Subclasses get the
    # environment's settings hash and the application root (paths in the
    # settings are relative to it).
    #
    # A backend is registered in Izen::Storage::SERVICES and named by the
    # `service:` setting in config/storage.yml.
    class Service
      def initialize(_settings, root:)
        @root = root
      end

      def store(_upload, key: nil)
        raise NotImplementedError
      end

      def read(_key)
        raise NotImplementedError
      end

      def delete(_key)
        raise NotImplementedError
      end

      def exist?(_key)
        raise NotImplementedError
      end

      # Enumerates stored objects as an array of `{ key:, size: }` hashes,
      # optionally restricted to keys starting with +prefix+. Used by
      # Izen::Backup to archive uploads on a backend that is not on this
      # machine (S3/R2). Backends that cannot enumerate return an empty array.
      def list(prefix: nil)
        []
      end

      def url(_key, **_options)
        raise NotImplementedError
      end
    end
  end
end
