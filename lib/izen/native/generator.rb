# frozen_string_literal: true

require "fileutils"
require "erubi"
require "yaml"
require_relative "analyzer"
require_relative "route_compiler"
require_relative "../cli/kamal"

module Izen
  module Native
    # Orchestrates the lowering: copies the Spinel-safe runtime, copies the
    # domain code untouched, and generates the metaprogrammed pieces.
    #
    #   Izen::Native::Generator.new("/path/to/app", "./native", spinel: true).run
    class Generator
      RUNTIME_DIR = File.expand_path("runtime", __dir__)
      SPINEL_DIR  = File.expand_path("spinel", __dir__)

      # `require`s that cannot be satisfied under Spinel (or are supplied by
      # the generated runtime) and are dropped from copied domain files.
      DROPPED_REQUIRES = %w[
        izen roda rack rack/method_override sqlite3 yaml securerandom date
        fileutils digest openssl logger bcrypt vips
      ].freeze

      attr_reader :source, :out

      def initialize(source, out, spinel: false, name: nil)
        @source = File.expand_path(source)
        @out    = File.expand_path(out)
        @an     = Analyzer.new(@source)
        @spinel = spinel
        @name   = sanitize_name(name || File.basename(@source))
      end

      def run
        prepare
        copy_runtime
        copy_spinel
        copy_domain
        copy_lib
        copy_public
        write_models
        write_contracts
        write_repositories
        write_app_helpers
        write_controller_helpers
        write_views
        write_routes
        write_requires
        write_database_config
        write_schema
        write_bin
        write_manifest
        write_gemfile
        write_rakefile
        write_docker
        write_kamal
        @out
      end

      private

      def prepare
        if @out == @source || @source.start_with?("#{@out}/")
          raise ArgumentError, "output directory #{@out} would contain the source app"
        end

        FileUtils.rm_rf(@out)
        %w[runtime generated app db storage bin spinel lib].each do |dir|
          FileUtils.mkdir_p(File.join(@out, dir))
        end
      end

      # --- runtime ----------------------------------------------------------

      def copy_runtime
        Dir[File.join(RUNTIME_DIR, "*.rb")].each do |path|
          base   = File.basename(path)
          target = base == "app.rb" ? File.join(@out, "app.rb") : File.join(@out, "runtime", base)
          FileUtils.cp(path, target)
        end
        return unless @spinel

        # The CRuby build uses the sqlite3 gem; Spinel links libsqlite3 through
        # the FFI adapter instead.
        app    = File.join(@out, "app.rb")
        source = File.read(app).sub('require_relative "runtime/database"', 'require_relative "spinel/database_spinel"')
        File.write(app, source)
      end

      def copy_spinel
        Dir[File.join(SPINEL_DIR, "*")].each do |path|
          FileUtils.cp(path, File.join(@out, "spinel", File.basename(path)))
        end
      end

      # --- domain code (copied; only unsatisfiable requires are stripped) ---

      def copy_domain
        (@an.controller_files + @an.repository_files).each do |path|
          module_name = File.basename(File.dirname(path))
          target_dir  = File.join(@out, "app", module_name)
          FileUtils.mkdir_p(target_dir)
          File.write(File.join(target_dir, File.basename(path)), strip_requires(File.read(path)))
        end
      end

      def copy_lib
        @an.lib_files.each do |path|
          relative = path.sub("#{@source}/", "")
          target   = File.join(@out, relative)
          FileUtils.mkdir_p(File.dirname(target))
          File.write(target, strip_requires(File.read(path)))
        end
      end

      def strip_requires(source)
        DROPPED_REQUIRES.each do |gem_name|
          # Match both top-level requires and ones nested inside methods/classes.
          source = source.gsub(/^\s*require ["']#{Regexp.escape(gem_name)}["']\s*\n/, "")
        end
        source
      end

      def copy_public
        directory = File.join(@source, "public")
        FileUtils.cp_r(directory, File.join(@out, "public")) if File.directory?(directory)
      end

      # --- models -----------------------------------------------------------

      def write_models
        out      = +"# frozen_string_literal: true\n\n"
        requires = @an.model_files.flat_map { |path| @an.model(path)[:requires] }.uniq
        requires.each { |line| out << "#{line}\n" }
        out << "\n"

        @an.model_files.each do |path|
          model = @an.model(path)
          out << "module #{model[:module]}\n"
          out << "  class #{model[:class]} < Base::Model\n"
          out << "    def self.attributes\n"
          out << "      {\n"
          model[:attributes].each do |attribute|
            out << "        #{attribute.name}: { type: #{attribute.type.inspect}, "
            out << "required: #{attribute.required}, default: #{attribute.default_source} },\n"
          end
          out << "      }\n"
          out << "    end\n\n"
          model[:attributes].each do |attribute|
            out << "    def #{attribute.name}\n"
            out << "      @attrs[:#{attribute.name}]\n"
            out << "    end\n"
          end
          model[:extra].each { |statement| out << "\n#{statement}\n" }
          out << "  end\n"
          out << "end\n\n"
        end

        File.write(File.join(@out, "generated", "models.rb"), out)
      end

      # --- contracts --------------------------------------------------------

      def write_contracts
        out = +"# frozen_string_literal: true\n\n"

        @an.contract_files.each do |path|
          contract = @an.contract(path)
          out << "module #{contract[:module]}\n"
          out << "  class #{contract[:class]} < Base::Contract\n"
          out << "    def self.fields\n"
          out << "      {\n"
          contract[:fields].each do |field|
            rendered = field.options.map { |key, value| "#{key}: #{value}" }.join(", ")
            out << "        #{field.name}: { #{rendered} },\n"
          end
          out << "      }\n"
          out << "    end\n"
          unless contract[:rules].empty?
            out << "\n    def rules\n"
            contract[:rules].each { |rule| out << "#{indent(rule, 6)}\n" }
            out << "    end\n"
          end
          out << "  end\n"
          out << "end\n\n"
        end

        File.write(File.join(@out, "generated", "contracts.rb"), out)
      end

      # --- repositories -----------------------------------------------------

      def write_repositories
        out = +"# frozen_string_literal: true\n\n"
        @an.repository_files.each do |path|
          module_name = @an.module_of(path)
          out << "module #{module_name}\n"
          out << "  class Repository\n"
          # `model_class.new(row)` calls `.new` on a class read out of a method,
          # which Spinel cannot type. Bind the model class literally instead.
          out << "    def to_model(row)\n"
          out << "      row && #{module_name}::Model.new(row)\n"
          out << "    end\n\n"
          out << "    def to_models(rows)\n"
          out << "      rows.map { |row| #{module_name}::Model.new(row) }\n"
          out << "    end\n"
          out << "  end\n"
          out << "end\n\n"
        end
        File.write(File.join(@out, "generated", "repositories.rb"), out)
      end

      # --- app helpers ------------------------------------------------------

      def write_app_helpers
        statements = @an.app_helper_source
        out        = +"# frozen_string_literal: true\n\n"
        out << "# App-specific helpers extracted from the source app.rb.\n"
        out << "module AppHelpers\n"
        statements.each { |statement| out << "#{indent(statement, 2)}\n" }
        out << "end\n"
        File.write(File.join(@out, "generated", "app_helpers.rb"), out)
      end

      # Spinel does not dispatch undefined-method calls to method_missing, so
      # app helpers are also exposed explicitly on Base::Controller (the
      # copied controllers call them as if they were their own methods).
      def write_controller_helpers
        names = @an.app_helper_methods
        out   = +"# frozen_string_literal: true\n\n"
        out << "module Base\n  class Controller\n"
        names.each do |name|
          out << "    def #{name}(*args, &block)\n"
          out << "      app.#{name}(*args, &block)\n"
          out << "    end\n"
        end
        out << "  end\nend\n"
        File.write(File.join(@out, "generated", "controller_helpers.rb"), out)
      end

      # --- views ------------------------------------------------------------

      def write_views
        locals_by_template = @an.render_locals
        out                = +"# frozen_string_literal: true\n\nmodule Views\n"

        views = @an.view_files.reject { |path| File.basename(path) == "layout.erb" }
        views.each do |path|
          template = template_name(path)
          locals   = locals_by_template[template] || []
          out << compile_view(path, "view_#{template.tr('/', '_')}", locals, nil)
          out << "\n"
        end

        layout = @an.view_files.find { |path| File.basename(path) == "layout.erb" }
        out << compile_view(layout, "layout_view", [], "content") if layout
        out << "\n"

        out << render_view_method(views, layout: !layout.nil?)

        out << "end\n"
        File.write(File.join(@out, "generated", "views.rb"), out)
      end

      # Spinel's parser rejects a `case` with no `when` branch, so an app that
      # ships only a layout (no module views yet) gets an empty inner body
      # instead. Likewise, only wrap in the layout when one exists.
      def render_view_method(views, layout:)
        out = +"  def view(template, locals: {})\n"
        if views.empty?
          out << "    inner = \"\"\n"
        else
          out << "    inner =\n"
          out << "      case template\n"
          views.each do |path|
            template = template_name(path)
            out << "      when #{template.inspect} then view_#{template.tr('/', '_')}(locals)\n"
          end
          out << "      else \"\"\n"
          out << "      end\n"
        end
        out << (layout ? "    layout_view(inner)\n" : "    inner\n")
        out << "  end\n"
        out
      end

      def compile_view(path, method_name, locals, replace_yield)
        source = File.read(path)
        source = source.gsub("yield", replace_yield) if replace_yield
        # Match Tilt::ErubiTemplate (what Izen uses through Roda's :render
        # plugin): no auto-escaping. `<%= %>` and `<%== %>` both emit raw HTML,
        # so the layout's `<%= yield %>` is not escaped and templates render
        # exactly as they do on CRuby. Templates that want escaping call `h`.
        engine = Erubi::Engine.new(source, bufvar: "@_buf")

        out = +"  def #{method_name}(#{replace_yield ? "content" : "locals"})\n"
        locals.each { |name| out << "    #{name} = locals[:#{name}]\n" }
        out << "    #{engine.src}\n"
        out << "  end\n"
        out
      end

      def template_name(path)
        path.sub("#{@source}/views/", "").sub(/\.erb\z/, "")
      end

      # --- routes -----------------------------------------------------------

      def write_routes
        block, source = @an.route_block
        body          = RouteCompiler.new(block, source).compile
        out           = +"# frozen_string_literal: true\n\nmodule Routes\n  def dispatch(r)\n"
        out << "#{indent(body, 4)}\n"
        out << "  end\nend\n"
        File.write(File.join(@out, "generated", "routes.rb"), out)
      end

      # --- requires, schema, bin, manifest ----------------------------------

      def write_requires
        out = +"# frozen_string_literal: true\n\n"
        out << "require_relative \"app_helpers\"\n"
        out << "require_relative \"controller_helpers\"\n"
        out << "require_relative \"models\"\n"
        out << "require_relative \"contracts\"\n"

        rewrite_app_requires.each { |line| out << "#{line}\n" }
        @an.lib_files.each do |path|
          relative = path.sub("#{@source}/", "").sub(/\.rb\z/, "")
          out << "require_relative \"../#{relative}\"\n"
        end

        (@an.controller_files + @an.repository_files).sort.each do |path|
          relative = path.sub("#{@source}/", "").sub(/\.rb\z/, "")
          out << "require_relative \"../#{relative}\"\n"
        end
        out << "require_relative \"repositories\"\n"
        out << "require_relative \"views\"\n"
        out << "require_relative \"routes\"\n"
        File.write(File.join(@out, "generated", "requires.rb"), out)
      end

      # `require_relative "x"` in the source app.rb is relative to the app
      # root; from generated/requires.rb it must point one level up.
      def rewrite_app_requires
        @an.app_requires.filter_map do |line|
          next if line.match?(/^require ["'](?:#{DROPPED_REQUIRES.map { |name| Regexp.escape(name) }.join("|")})["']/)

          line.sub(/^require_relative /, 'require_relative "../')
        end.uniq
      end

      def write_database_config
        paths = database_paths
        out   = +"# frozen_string_literal: true\n\n"
        out << "# Storage paths baked in at generation time (YAML is unavailable\n"
        out << "# under Spinel). Mirrors config/database.yaml in the source app.\n"
        out << "module DatabaseConfig\n"
        out << "  DEFAULT_PATH = #{paths.fetch("development", "storage/development.db").inspect}\n\n"
        out << "  PATHS = {\n"
        paths.each { |env, path| out << "    #{env.inspect} => #{path.inspect},\n" }
        out << "  }.freeze\n"
        out << "end\n"
        File.write(File.join(@out, "generated", "database_config.rb"), out)
      end

      def database_paths
        config_path = %w[config/database.yaml config/database.yml]
                      .map { |path| File.join(@source, path) }
                      .find { |path| File.file?(path) }
        return default_database_paths unless config_path

        config = YAML.load_file(config_path) || {}
        paths  = {}
        config.each do |env, settings|
          next unless settings.is_a?(Hash) && settings["path"]

          paths[env.to_s] = settings["path"].to_s
        end
        paths.empty? ? default_database_paths : paths
      end

      def default_database_paths
        {
          "development" => "storage/development.db",
          "test"        => "storage/test.db",
          "production"  => "storage/production.db"
        }
      end

      def write_schema
        schema = Dir[File.join(@source, "migrations", "*.up.sql")].sort.map { |path| File.read(path) }.join("\n")
        File.write(File.join(@out, "db", "schema.sql"), schema)
      end

      def write_bin
        File.write(File.join(@out, "bin", "serve.rb"), <<~RUBY)
          # frozen_string_literal: true

          require_relative "../app"
          require_relative "../runtime/server"

          Database.migrate!   # idempotent; adopts an existing database
          Server.run
        RUBY
      end

      def write_manifest
        File.write(File.join(@out, "spin.toml"), <<~TOML)
          [package]
          name = #{@name.inspect}
          version = "0.1.0"
          sources = ["spinel/sqlite_shim.c"]
        TOML
        FileUtils.touch(File.join(@out, "storage", ".keep"))
      end

      def write_gemfile
        File.write(File.join(@out, "Gemfile"), <<~RUBY)
          # frozen_string_literal: true

          # Used only by the CRuby development / test path of the generated
          # project. The Spinel binary links libsqlite3 through the FFI adapter
          # and does not use this Gemfile.
          source "https://rubygems.org"

          gem "sqlite3", "~> 2.0"

          group :test do
            gem "minitest", "~> 5.25"
            gem "rake", "~> 13.0"
          end
        RUBY
      end

      def write_rakefile
        File.write(File.join(@out, "Rakefile"), <<~RUBY)
          # frozen_string_literal: true

          require "rake/testtask"

          Rake::TestTask.new(:test) do |task|
            task.libs << "test"
            task.test_files = FileList["test/**/*_test.rb"]
            task.warning = false
          end

          desc "Run the generated app on CRuby (development)"
          task :serve do
            sh "ruby bin/serve.rb"
          end

          task default: :test
        RUBY
      end

      def write_docker
        File.write(File.join(@out, "Dockerfile"), <<~DOCKER)
          # syntax=docker/dockerfile:1
          # Build the Spinel binary from the packed C sources, then ship a minimal
          # runtime image. Build context is this directory; run `spin pack` first.
          FROM debian:bookworm-slim AS build
          RUN apt-get update -qq \\
           && apt-get install --no-install-recommends -y clang make libsqlite3-dev libssl-dev libcrypt-dev \\
           && rm -rf /var/lib/apt/lists/*
          COPY pack /src
          RUN make -C /src clean || true
          RUN make -C /src -j"$(nproc)" CC=clang

          FROM debian:bookworm-slim
          RUN apt-get update -qq \\
           && apt-get install --no-install-recommends -y libsqlite3-0 libssl3 libcrypt1 \\
           && rm -rf /var/lib/apt/lists/*
          WORKDIR /app
          COPY public/ ./public/
          COPY db/ ./db/
          COPY --from=build /src/serve ./serve
          RUN useradd --uid 1001 --create-home app \\
           && mkdir -p storage \\
           && chown -R app:app /app
          USER app
          VOLUME /app/storage
          ENV APP_ENV=production
          ENV PORT=3000
          ENV SPINEL_WORKERS=2
          EXPOSE 3000
          CMD ["./serve"]
        DOCKER

        File.write(File.join(@out, ".dockerignore"), <<~IGNORE)
          build/
          storage/
          test/
          vendor/
          app/
          generated/
          runtime/
          spinel/
          bin/
          *.md
          spin.lock
          pack/**/*.o
        IGNORE
      end

      # Kamal deploy config for the native binary. The source app's
      # config/deploy.yml is reused when present (it holds the real servers,
      # host and registry); otherwise a working default is generated. Either way
      # the proxy port is pinned to 3000 to match the generated Dockerfile, and
      # an empty .kamal/secrets is written so `kamal deploy` can start.
      def write_kamal
        FileUtils.mkdir_p(File.join(@out, "config"))
        File.write(File.join(@out, "config", "deploy.yml"), native_deploy_yml)

        FileUtils.mkdir_p(File.join(@out, ".kamal"))
        write_kamal_secrets
        copy_kamal_extras
      end

      def native_deploy_yml
        deploy = File.join(@source, "config", "deploy.yml")
        text   = File.file?(deploy) ? File.read(deploy) : Izen::Cli::Kamal.deploy_yml(@name)

        text = text.gsub(/^(\s*)#\s*app_port:\s*\d+\s*$/, '\1app_port: 3000')
        unless text.include?("app_port: 3000")
          text = text.sub(/^(proxy:\s*\n)/, "\\1  app_port: 3000\n")
        end
        text
      end

      def write_kamal_secrets
        source = File.join(@source, ".kamal", "secrets")
        target = File.join(@out, ".kamal", "secrets")
        if File.file?(source)
          FileUtils.cp(source, target)
        else
          File.write(target, Izen::Cli::Kamal.secrets(@name))
        end
      end

      # Any other files the source app keeps under .kamal/ (hooks, keys, ...)
      # are copied through untouched.
      def copy_kamal_extras
        kamal = File.join(@source, ".kamal")
        return unless File.directory?(kamal)

        Dir[File.join(kamal, "**", "*")].each do |path|
          next if File.directory?(path) || File.basename(path) == "secrets"

          relative = path.sub("#{kamal}/", "")
          target   = File.join(@out, ".kamal", relative)
          FileUtils.mkdir_p(File.dirname(target))
          FileUtils.cp(path, target)
        end
      end

      def indent(text, spaces)
        pad = " " * spaces
        text.to_s.split("\n", -1).map { |line| line.empty? ? line : "#{pad}#{line}" }.join("\n")
      end

      def sanitize_name(name)
        name.to_s.gsub(/[^a-zA-Z0-9_]/, "_").gsub(/\A(\d)/, '_\1')
      end
    end
  end
end
