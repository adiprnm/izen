# frozen_string_literal: true

# Spinel build variant of runtime/database.rb.
#
# Spinel cannot load a C-extension gem, so it links libsqlite3 directly through
# the FFI adapter in sqlite_ffi.rb (backed by sqlite_shim.c). The generator
# points app.rb at this file when building for Spinel.
require_relative "sqlite_ffi"
require_relative "../generated/database_config"

module Database
  # Thread-local key for the per-thread connection, matching Izen::Database.
  # Kept generic (not tied to this app's name) so the module can be dropped
  # into any project as-is.
  THREAD_KEY = :database_connection

  class << self
    # The app root. The native binary runs with the app as its working
    # directory, so a relative path is the root (`Izen::Database.root`).
    def root
      "."
    end

    def env
      ENV.fetch("APP_ENV", "development")
    end

    def path
      DatabaseConfig::PATHS.fetch(env, DatabaseConfig::DEFAULT_PATH)
    end

    # One connection per thread: the server runs a green thread per client
    # connection and SQLite connections are not safe to share. A single global
    # connection serialised every query behind one mutex, which capped request
    # throughput even with the rest of the M:N scheduler idle.
    def connection
      conn = Thread.current[THREAD_KEY]
      return conn if conn

      conn                       = connect
      Thread.current[THREAD_KEY] = conn
      conn
    end

    def connect
      directory = File.dirname(path)
      Dir.mkdir(directory) unless File.directory?(directory)
      adapter   = SqliteAdapter.new(path)
      adapter.execute("PRAGMA busy_timeout = 5000")
      adapter.execute("PRAGMA journal_mode = WAL")
      adapter.execute("PRAGMA foreign_keys = ON")
      adapter
    end

    def migrate!
      directory = File.dirname(path)
      Dir.mkdir(directory) unless File.directory?(directory)
      connection.execute_batch(File.read("db/schema.sql"))
    end

    def disconnect
      conn = Thread.current[THREAD_KEY]
      return unless conn

      Thread.current[THREAD_KEY] = nil
      conn.close
    end
  end
end
