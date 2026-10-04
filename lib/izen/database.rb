# frozen_string_literal: true

require "sqlite3"
require "fileutils"

require_relative "config"

# Owns the single SQLite connection for the process.
#
# The database file is read from config/database.yaml for the current
# environment (APP_ENV, defaulting to "development").
module Izen
  module Database
    # Thread-local key for the per-thread connection. Kept generic (not tied to
    # this app's name) so the module can be dropped into any project as-is.
    THREAD_KEY = :database_connection

    class << self
      # One connection per thread: the web process may run background jobs on
      # separate threads, and SQLite connections are not safe to share.
      def connection
        Thread.current[THREAD_KEY] ||= connect
      end

      def config
        @config ||= Izen::Config.load_yaml(config_path)
      end

      def env
        ENV.fetch("APP_ENV", "development")
      end

      # Host application root (where config/database.yaml lives).
      def root
        Izen.root
      end

      def config_path
        candidates = %w[config/database.yaml config/database.yml].map { |path| File.join(root, path) }
        candidates.find { |path| File.file?(path) } ||
          raise("missing database config (looked in #{candidates.join(", ")})")
      end

      def database_path
        File.expand_path(config.fetch(env).fetch("path"), root)
      end

      def connect
        FileUtils.mkdir_p(File.dirname(database_path))
        db = SQLite3::Database.new(database_path, results_as_hash: true)
        db.execute("PRAGMA journal_mode = WAL")
        db.execute("PRAGMA foreign_keys = ON")
        db
      end

      def disconnect
        Thread.current[THREAD_KEY]&.close
        Thread.current[THREAD_KEY] = nil
      end
    end
  end
end
