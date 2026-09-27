# frozen_string_literal: true

require "erb"
require "fileutils"

module Izen
  module Cli
    # Scaffolds a domain module: app files, colocated tests, views, a migration
    # and a route entry in app.rb.
    #
    #   Cli::ModuleGenerator.new("posts", [["title", "string"]]).call
    #
    # File templates live in lib/cli/templates/module/*.tt and are rendered with ERB
    # in the context of this generator (so they can use @name, @fields, and the
    # helper methods below).
    class ModuleGenerator
      Field = Struct.new(:name, :type, :required, :default, keyword_init: true)

      SUPPORTED_TYPES = %w[string text integer float boolean date datetime time].freeze
      RESERVED_NAMES  = %w[id created_at updated_at].freeze
      ROUTES_MARKER   = "# cli:module-routes"
      TEMPLATES_DIR   = File.expand_path("templates/module", __dir__)

      RUBY_TYPE = {
        "string" => "String", "text" => "String", "integer" => "Integer",
        "float" => "Float", "boolean" => ":boolean", "date" => "Date",
        "datetime" => "Time", "time" => "Time"
      }.freeze

      SQL_TYPE = {
        "string"   => "TEXT NOT NULL",
        "text"     => "TEXT NOT NULL DEFAULT ''",
        "integer"  => "INTEGER NOT NULL",
        "float"    => "REAL NOT NULL",
        "boolean"  => "INTEGER NOT NULL DEFAULT 0",
        "date"     => "TEXT NOT NULL",
        "datetime" => "TEXT NOT NULL",
        "time"     => "TEXT NOT NULL"
      }.freeze

      def initialize(name, field_pairs, tests: true, views: true, migration: true, routes: true, force: false)
        @name      = normalize_name(name)
        @namespace = camelize(@name)
        @fields    = build_fields(field_pairs)
        @primary   = @fields.first
        @tests     = tests
        @views     = views
        @migration = migration
        @routes    = routes
        @force     = force
        @root      = Cli.root
      end

      def call
        ensure_target!

        write_app_files
        write_test_files if @tests
        write_view_files if @views
        write_migration_file if @migration
        add_routes if @routes

        summary
      end

      private

      # --- output ------------------------------------------------------------

      def write_app_files
        write("app/#{@name}/model.rb",       render("model.rb.tt"))
        write("app/#{@name}/contract.rb",    render("contract.rb.tt"))
        write("app/#{@name}/repository.rb",  render("repository.rb.tt"))
        write("app/#{@name}/controller.rb",  render("controller.rb.tt"))
      end

      def write_test_files
        write("app/#{@name}/model_test.rb",      render("model_test.rb.tt"))
        write("app/#{@name}/contract_test.rb",   render("contract_test.rb.tt"))
        write("app/#{@name}/repository_test.rb", render("repository_test.rb.tt"))
        write("app/#{@name}/controller_test.rb", render("controller_test.rb.tt"))
      end

      def write_view_files
        write("views/#{@name}/index.erb", render("index.erb.tt"))
        write("views/#{@name}/show.erb",  render("show.erb.tt"))
        write("views/#{@name}/new.erb",   render("new.erb.tt"))
        write("views/#{@name}/edit.erb",  render("edit.erb.tt"))
      end

      def write_migration_file
        Cli.write_migration(
          "create_#{@name}",
          render("migration.up.sql.tt"),
          render("migration.down.sql.tt")
        )
      end

      def write(relative_path, content)
        path = File.join(@root, relative_path)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, content)
        puts "created #{relative_path}"
      end

      def ensure_target!
        dir = File.join(@root, "app", @name)
        return unless Dir.exist?(dir) && !@force

        abort "app/#{@name} already exists (use --force to overwrite)"
      end

      # Renders a .tt template in this generator's binding.
      def render(template)
        source = File.read(File.join(TEMPLATES_DIR, template))
        ERB.new(source, trim_mode: "-").result(binding)
      end

      # --- routes ------------------------------------------------------------

      def add_routes
        path   = File.join(@root, "app.rb")
        source = File.read(path)

        if source.include?("r.on \"#{@name}\" do")
          puts "skipped routes (/#{@name} already registered in app.rb)"
          return
        end

        marker = source.index(ROUTES_MARKER)
        unless marker
          puts "! could not find #{ROUTES_MARKER.inspect} in app.rb; add these routes manually:"
          puts routes_snippet
          return
        end

        line_start = source[0...marker].rindex("\n")
        line_start = line_start ? line_start + 1 : 0
        source.insert(line_start, "#{routes_snippet}\n")
        File.write(path, source)
        puts "updated app.rb (added /#{@name} routes)"
      end

      def routes_snippet
        render("routes.rb.tt").chomp
      end

      # --- template helpers --------------------------------------------------

      def ruby_type(field)
        RUBY_TYPE.fetch(field.type)
      end

      def sql_type(field)
        SQL_TYPE.fetch(field.type)
      end

      def bind_value(field)
        case field.type
        when "boolean"
          "model.#{field.name} ? 1 : 0"
        when "date", "datetime", "time"
          "model.#{field.name}&.to_s"
        else
          "model.#{field.name}"
        end
      end

      def first_required
        @fields.find(&:required)
      end

      def model_hash_literal
        "{ #{@fields.map { |field| "#{field.name}: #{model_sample(field)}" }.join(", ")} }"
      end

      def param_hash_literal(overrides = {})
        pairs = @fields.map do |field|
          value = overrides.key?(field.name) ? overrides[field.name] : param_sample(field)
          "\"#{field.name}\" => #{value.inspect}"
        end
        "{ #{pairs.join(", ")} }"
      end

      def model_sample(field)
        case field.type
        when "string"  then '"sample"'
        when "text"    then '"sample text"'
        when "integer" then "1"
        when "float"   then "1.5"
        when "boolean" then "true"
        else '"2026-01-02 03:04:05"'
        end
      end

      def param_sample(field)
        case field.type
        when "string"  then "sample"
        when "text"    then "sample text"
        when "integer" then "1"
        when "float"   then "1.5"
        when "boolean" then "true"
        else "2026-01-02 03:04:05"
        end
      end

      def form_fields
        @fields.map do |field|
          "  <label>\n    #{humanize(field.name)}\n    #{input_tag(field)}\n  </label>"
        end.join("\n")
      end

      def field_rows
        @fields.map do |field|
          "  <dt>#{humanize(field.name)}</dt>\n  <dd><%= item.#{field.name} %></dd>"
        end.join("\n")
      end

      def input_tag(field)
        name = field.name

        case field.type
        when "text"
          "<textarea name=\"#{name}\"><%= item.#{name} %></textarea>"
        when "boolean"
          "<input type=\"checkbox\" name=\"#{name}\" value=\"1\" <%= \"checked\" if item.#{name} %>>"
        when "integer"
          "<input type=\"number\" name=\"#{name}\" value=\"<%= item.#{name} %>\">"
        when "float"
          "<input type=\"number\" step=\"any\" name=\"#{name}\" value=\"<%= item.#{name} %>\">"
        when "date"
          "<input type=\"date\" name=\"#{name}\" value=\"<%= item.#{name} %>\">"
        else
          "<input type=\"text\" name=\"#{name}\" value=\"<%= item.#{name} %>\">"
        end
      end

      def humanize(name)
        name.tr("_", " ").capitalize
      end

      # --- input -------------------------------------------------------------

      def build_fields(field_pairs)
        pairs = field_pairs.empty? ? [ %w[name string], %w[description text] ] : field_pairs

        pairs.map do |(name, type)|
          name = normalize_field_name(name)
          type = (type || "string").downcase

          unless SUPPORTED_TYPES.include?(type)
            abort "unsupported field type #{type.inspect} for :#{name} " \
                  "(supported: #{SUPPORTED_TYPES.join(", ")})"
          end

          required = !%w[text boolean].include?(type)
          default  = case type
          when "text"    then ""
          when "boolean" then false
          end

          Field.new(name: name, type: type, required: required, default: default)
        end
      end

      def normalize_name(name)
        normalized = name.to_s
                         .gsub(/([a-z\d])([A-Z])/, '\1_\2')
                         .tr("-", "_")
                         .downcase

        unless normalized.match?(/\A[a-z][a-z0-9_]*\z/)
          abort "invalid module name #{name.inspect} (use snake_case, e.g. blog_posts)"
        end

        normalized
      end

      def normalize_field_name(name)
        normalized = name.to_s.tr("-", "_").downcase

        unless normalized.match?(/\A[a-z][a-z0-9_]*\z/)
          abort "invalid field name #{name.inspect}"
        end

        abort "field name #{normalized.inspect} is reserved" if RESERVED_NAMES.include?(normalized)

        normalized
      end

      def camelize(name)
        name.split("_").map(&:capitalize).join
      end

      def summary
        puts
        puts "Module #{@namespace} scaffolded in app/#{@name}."
        puts "Run `bundle exec izen migration migrate` to create the `#{@name}` table." if @migration
      end
    end
  end
end
