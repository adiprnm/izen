# frozen_string_literal: true

require_relative "base/repository"

module Izen
  # Small database-backed rate limiter.
  #
  # A fixed window per key: the first hit opens a window of +window+ seconds and
  # each subsequent hit increments the counter. The call returns true while the
  # count is within +limit+. Keys are namespaced by the caller:
  #
  #   Izen::RateLimit.allow?("login:203.0.113.7", limit: 10, window: 300)
  #   Izen::RateLimit.allow?("pay:#{order.number}", limit: 5, window: 600)
  #
  # Backed by the database (not process memory) so the limit holds when the app
  # runs more than one worker and when a request lands on a different instance.
  #
  # The `rate_limits` table is created by the migration `izen new` scaffolds
  # (`create_rate_limits`), so it shows up in `izen migration status` like any
  # other table. `ensure_table!` is available for tests and one-off scripts but
  # is not called automatically — call it, or run the migration, before the
  # first `allow?`.
  module RateLimit
    TABLE = "rate_limits"

    class Repository < Izen::Base::Repository
      # Atomically increments the counter for +key+ and returns the new count.
      # A row whose window already elapsed is reset to 1 with a fresh expiry.
      def hit(key, window:, now: Time.now.utc)
        expires = now + window
        params  = [ key.to_s, sqlite_time(expires), sqlite_time(now), sqlite_time(now), sqlite_time(expires) ]
        row     = find_one(<<~SQL, params)
          INSERT INTO #{TABLE} (key, count, expires_at)
          VALUES (?, 1, ?)
          ON CONFLICT(key) DO UPDATE SET
            count      = CASE WHEN #{TABLE}.expires_at <= ? THEN 1 ELSE #{TABLE}.count + 1 END,
            expires_at = CASE WHEN #{TABLE}.expires_at <= ? THEN ? ELSE #{TABLE}.expires_at END,
            updated_at = datetime('now')
          RETURNING count
        SQL
        row[:count].to_i
      end

      def clear(key)
        db.execute("DELETE FROM #{TABLE} WHERE key = ?", [ key.to_s ])
      end

      # Drops windows that ended before +now+ so the table does not grow without
      # bound.
      def sweep(now: Time.now.utc)
        db.execute("DELETE FROM #{TABLE} WHERE expires_at < ?", [ sqlite_time(now) ])
      end
    end

    class << self
      def repository
        @repository ||= Repository.new
      end

      # Creates the table when missing. Idempotent; `izen new` already scaffolds
      # a migration for it, so this is mainly for tests and scripts. Not called
      # by #allow?.
      def ensure_table!
        Izen::Database.connection.execute(<<~SQL)
          CREATE TABLE IF NOT EXISTS #{TABLE} (
            key        TEXT PRIMARY KEY,
            count      INTEGER NOT NULL DEFAULT 0,
            expires_at TEXT NOT NULL,
            updated_at TEXT NOT NULL DEFAULT (datetime('now'))
          );
        SQL
        Izen::Database.connection.execute(
          "CREATE INDEX IF NOT EXISTS index_#{TABLE}_on_expires_at ON #{TABLE} (expires_at);"
        )
      end

      # Returns true when the request is allowed (count <= limit). Increments the
      # counter as a side effect, so a denied request still counts.
      def allow?(key, limit:, window: 60, now: Time.now.utc)
        count = repository.hit(key, window: window, now: now)
        repository.sweep(now: now) if count == 1
        count <= limit.to_i
      end

      # Reads the counter without incrementing.
      def count(key)
        row = Izen::Database.connection.get_first_row(
          "SELECT count FROM #{TABLE} WHERE key = ? LIMIT 1", [ key.to_s ]
        )
        row ? row["count"].to_i : 0
      end

      def clear(key)
        repository.clear(key)
      end

      # Drops the memoized repository (tests / APP_ENV changes).
      def reset!
        @repository = nil
      end
    end
  end
end
