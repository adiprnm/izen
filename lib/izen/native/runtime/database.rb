# frozen_string_literal: true

require "sqlite3"
require "monitor"
require_relative "../generated/database_config"

# CRuby build of the generated project's database layer.
#
# The sqlite3 gem is used for development and for the request-cycle tests; the
# Spinel build swaps this file for `spinel/database_spinel.rb` (FFI adapter).
# The storage paths are baked into generated/database_config.rb at generation
# time (YAML is unavailable under Spinel).
class SqliteCrubyAdapter
  def initialize(path)
    @db      = SQLite3::Database.new(path, results_as_hash: true)
    @monitor = Monitor.new
  end

  def execute(sql, params = [])
    @monitor.synchronize { @db.execute(sql, params) }
  end

  def get_first_row(sql, params = [])
    @monitor.synchronize { @db.get_first_row(sql, params) }
  end

  def get_first_value(sql, params = [])
    @monitor.synchronize { @db.get_first_value(sql, params) }
  end

  def transaction(&block)
    @monitor.synchronize { @db.transaction(&block) }
  end

  def execute_batch(sql)
    @monitor.synchronize { @db.execute_batch(sql) }
  end

  def close
    @monitor.synchronize { @db.close }
  end
end

# Owns one SQLite connection per thread (see Izen::Database).
module Database
  # Thread-local key for the per-thread connection, matching Izen::Database.
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

    # One connection per thread: the server runs a thread per client
    # connection and SQLite connections are not safe to share. A single global
    # connection serialised every query behind one mutex.
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
      db        = SqliteCrubyAdapter.new(path)
      db.execute("PRAGMA busy_timeout = 5000")
      db.execute("PRAGMA journal_mode = WAL")
      db.execute("PRAGMA foreign_keys = ON")
      db
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
