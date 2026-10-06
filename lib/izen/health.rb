# frozen_string_literal: true

require_relative "database"

module Izen
  # Shallow liveness/readiness probe: the database answers a trivial query and
  # the schema is migrated. Used by `Izen::Application#health`, but callable
  # from a Rake task or a custom route too.
  #
  #   Izen::Health.call # => { status: "ok", database: "ok", migration: 24 }
  #   Izen::Health.ok?  # => true
  module Health
    module_function

    def call
      database  = Izen::Database.connection.get_first_value("SELECT 1") == 1 ? "ok" : "error"
      migration = Izen::Database.connection.get_first_value("SELECT MAX(version) FROM schema_migrations")

      {
        status:    database == "ok" ? "ok" : "degraded",
        database:  database,
        migration: migration
      }
    rescue StandardError => error
      { status: "error", database: "error", error: error.class.name }
    end

    def ok?
      call[:status] == "ok"
    end
  end
end
