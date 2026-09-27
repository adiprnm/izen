# frozen_string_literal: true

require "fileutils"

require_relative "database"
require_relative "cli/module_generator"
require_relative "cli/project_generator"

# Command line interface. Commands are grouped by concern.
#
#   izen new blog
#   izen migration migrate
#   izen migration rollback [STEP]
#   izen migration status
#   izen migration generate create_users
#   izen module new posts title:string body:text
#
# The target environment is selected with APP_ENV (development by default):
#
#   APP_ENV=test izen migration migrate
module Izen
  module Cli
    VERSION_FORMAT = "%06d"

    module_function

    def connection
      Database.connection
    end

    # SQLite has no nested transactions; when a caller (e.g. a test) already
    # opened one, just run the block in place.
    def transaction(&block)
      return yield if connection.transaction_active?

      connection.transaction(&block)
    end

    def ensure_schema_migrations!
      connection.execute(<<~SQL)
        CREATE TABLE IF NOT EXISTS schema_migrations (
          version    INTEGER NOT NULL PRIMARY KEY,
          applied_at TEXT    NOT NULL DEFAULT (datetime('now'))
        );
      SQL
    end

    def applied_versions
      connection.execute("SELECT version FROM schema_migrations ORDER BY version")
                .map { |row| row["version"].to_i }
    end

    def migration_files(suffix)
      Dir[File.join(migrations_dir, "*#{suffix}")].sort
    end

    def version_of(path)
      File.basename(path).split("_").first.to_i
    end

    def next_version
      (migration_files(".up.sql").map { |file| version_of(file) }.max || 0) + 1
    end

    # Writes a versioned up/down pair and returns the version integer.
    def write_migration(name, up_sql, down_sql)
      version = format(VERSION_FORMAT, next_version)

      { "up" => up_sql, "down" => down_sql }.each do |direction, sql|
        path = File.join(migrations_dir, "#{version}_#{name}.#{direction}.sql")
        File.write(path, sql)
        puts "created #{relative(path)}"
      end

      version
    end

    # Creates an empty up/down pair with the next sequential version.
    def generate(name)
      abort "migration name is required" if name.nil? || name.empty?

      write_migration(name, "-- up migration: #{name}\n", "-- down migration: #{name}\n")
    end

    # Scaffolds a domain module (app files, tests, views, migration, routes).
    def scaffold(name, field_pairs = [], **options)
      ModuleGenerator.new(name, field_pairs, **options).call
    end

    # Runs all pending up migrations in order.
    def migrate
      ensure_schema_migrations!
      applied = applied_versions
      pending = migration_files(".up.sql").reject { |file| applied.include?(version_of(file)) }

      if pending.empty?
        puts "nothing to migrate"
        return
      end

      pending.each do |file|
        transaction do
          connection.execute_batch(File.read(file))
          connection.execute("INSERT INTO schema_migrations (version) VALUES (?)", [ version_of(file) ])
        end
        puts "migrated #{File.basename(file)}"
      end
    end

    # Rolls back the most recent +step+ migrations.
    def rollback(step = 1)
      ensure_schema_migrations!
      applied = applied_versions

      targets = migration_files(".down.sql")
                .select { |file| applied.include?(version_of(file)) }
                .sort_by { |file| version_of(file) }
                .reverse
                .first(step)

      if targets.empty?
        puts "nothing to rollback"
        return
      end

      targets.each do |file|
        transaction do
          connection.execute_batch(File.read(file))
          connection.execute("DELETE FROM schema_migrations WHERE version = ?", [ version_of(file) ])
        end
        puts "rolled back #{File.basename(file)}"
      end
    end

    def status
      ensure_schema_migrations!
      applied = applied_versions

      migration_files(".up.sql").each do |file|
        state = applied.include?(version_of(file)) ? "up" : "pending"
        puts format("%-8s %s", state, File.basename(file))
      end
    end

    def relative(path)
      path.delete_prefix("#{root}/")
    end

    def root
      Izen.root
    end

    def migrations_dir
      File.join(root, "migrations")
    end

    # Dispatches a CLI invocation. Kept separate from the script body so this
    # module can be required (e.g. from tests) without running the CLI.
    #
    # Commands are grouped by concern: `migration ...` and `module ...`.
    def run(argv)
      group  = argv.shift
      action = argv.shift

      case group
      when "migration", "db"
        run_migration(action, argv)
      when "module", "modules"
        run_module(action, argv)
      when "new", "init"
        project_new([ action, *argv ])
      when "-h", "--help", nil
        puts usage
      else
        abort "unknown command group: #{group} (run with --help)"
      end
    end

    # Handles `migration <command> [args]`.
    def run_migration(action, argv)
      case action
      when "generate", "g"
        generate(argv.shift)
      when "migrate", "m"
        migrate
      when "rollback", "r"
        rollback((argv.shift || 1).to_i)
      when "status", "s"
        status
      when nil, "-h", "--help"
        puts usage
      else
        abort "unknown migration command: #{action} (run with --help)"
      end
    end

    # Handles `module <command> [args]`.
    def run_module(action, argv)
      case action
      when "new", "scaffold", "generate", "g"
        module_new(argv)
      when nil, "-h", "--help"
        puts usage
      else
        abort "unknown module command: #{action} (run with --help)"
      end
    end

    # Parses `module new NAME [field:type ...] [options]`.
    def module_new(argv)
      name = argv.shift
      abort "module name is required" if name.nil? || name.empty?

      options = {}
      fields  = []

      argv.each do |arg|
        case arg
        when "--no-test"      then options[:tests]     = false
        when "--no-views"     then options[:views]     = false
        when "--no-migration" then options[:migration] = false
        when "--no-routes"    then options[:routes]    = false
        when "--force"        then options[:force]     = true
        when /\A--/           then abort "unknown option: #{arg}"
        else
          fields << (arg.include?(":") ? arg.split(":", 2) : [ arg, "string" ])
        end
      end

      scaffold(name, fields, **options)
    end

    # Scaffolds a new project directory: `izen new NAME [options]`.
    def project_new(argv)
      first = argv.first
      if first.nil? || %w[-h --help].include?(first)
        puts usage
        return
      end

      options = {}
      name    = nil

      argv.each do |arg|
        case arg
        when "--force"   then options[:force] = true
        when "--no-test" then options[:tests] = false
        when /\A--/      then abort "unknown option: #{arg}"
        else
          abort "unexpected argument: #{arg}" if name

          name = arg
        end
      end

      ProjectGenerator.new(name, **options).call
    end

    def usage
      <<~USAGE
        Usage: izen <group> <command> [args]

        New project:
          new NAME                      scaffold a new project in ./NAME

        Migration:
          migration generate NAME       create an empty up/down migration pair
          migration migrate             run all pending up migrations
          migration rollback [STEP]     roll back the last STEP migrations (default 1)
          migration status              show applied and pending migrations

        Module:
          module new NAME [field:type ...]
                                        scaffold a domain module

        New options:
          --no-test                     skip test files
          --force                       scaffold into a non-empty directory

        Module options:
          --no-test                     skip test files
          --no-views                    skip view templates
          --no-migration                skip the migration pair
          --no-routes                   skip adding routes to app.rb
          --force                       overwrite an existing module directory

        Field types: string (default), text, integer, float, boolean, date,
                     datetime, time

        Examples:
          izen new blog
          izen migration generate create_users
          izen migration migrate
          izen migration rollback 2
          izen module new posts title:string body:text

        Environment: APP_ENV=#{Database.env}
      USAGE
    end
  end
end
