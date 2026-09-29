# frozen_string_literal: true

require "fileutils"
require "erubi"
require "yaml"
require_relative "analyzer"
require_relative "route_compiler"
require_relative "../cli/kamal"
require_relative "../cli/native_assets"

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
        izen roda rack rack/method_override rack/auth/basic rack/mime rack/test
        sqlite3 yaml securerandom date openssl logger bcrypt vips
        aws-sdk-s3 nokogiri sanitize rufus-scheduler mail minitest
        minitest/autorun time
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
        copy_support
        copy_overrides
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
        write_dockerignore
        ensure_native_assets
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
          copy_source_file(path)
        end
      end

      # Helper modules, services and value objects under app/ that the copied
      # controllers, repositories and views reference.
      def copy_support
        @an.support_files.each { |path| copy_source_file(path) }
      end

      # App-supplied Spinel-friendly replacements. `native_overrides/` in the
      # source app mirrors the generated layout; any file there overwrites the
      # copied/derived output at the same relative path. This keeps the CRuby
      # app untouched while letting a file that uses unsupported constructs
      # ship a lowered variant.
      def copy_overrides
        directory = File.join(@source, "native_overrides")
        return unless File.directory?(directory)

        Dir[File.join(directory, "**", "*")].each do |path|
          next if File.directory?(path)

          relative = path.sub("#{directory}/", "")
          target   = File.join(@out, relative)
          FileUtils.mkdir_p(File.dirname(target))
          FileUtils.cp(path, target)
        end
      end

      # Copies one source file, preserving its path relative to the app root
      # (so nested modules such as admin/posts/controller.rb keep their place).
      def copy_source_file(path)
        relative = path.sub("#{@source}/", "")
        target   = File.join(@out, relative)
        FileUtils.mkdir_p(File.dirname(target))
        File.write(target, rewrite_constants(strip_requires(File.read(path))))
      end

      # Spinel resolves a qualified constant by its LEAF. `Izen::Base::X`
      # (whose `Izen::Base` alias points at `Base`) therefore collides with any
      # other class sharing that leaf and can bind to the wrong superclass; the
      # lowered runtime declares the base classes as `Base::X`, so rewrite the
      # namespace to match before the compiler sees it.
      def rewrite_constants(source)
        source
          .gsub("Izen::Base::", "Base::")
          .gsub("Izen::Database", "Database")
          .gsub("Izen::Encryptor", "Encryptor")
          .gsub("Izen::HTTP", "HTTP")
          # Spinel's bundled digest has no SHA512; the runtime shim provides a
          # top-level SHA512 (see shims.rb) to avoid shadowing CRuby's real
          # Digest::SHA512 class.
          .gsub("Digest::SHA512", "SHA512")
      end

      def copy_lib
        @an.lib_files.each do |path|
          relative = path.sub("#{@source}/", "")
          target   = File.join(@out, relative)
          FileUtils.mkdir_p(File.dirname(target))
          File.write(target, rewrite_constants(strip_requires(File.read(path))))
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
            out << "    def #{attribute.name}=(value)\n"
            out << "      @attrs[:#{attribute.name}] = value\n"
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
        methods = @an.app_helper_methods
        out     = +"# frozen_string_literal: true\n\n"
        out << "module Base\n  class Controller\n"
        methods.each do |method|
          out << "    def #{method[:name]}(#{method[:params]})\n"
          out << "      app.#{method[:name]}(#{method[:forward]})\n"
          out << "    end\n"
        end
        out << "  end\nend\n"
        File.write(File.join(@out, "generated", "controller_helpers.rb"), out)
      end

      # --- views ------------------------------------------------------------

      def write_views
        locals_by_template = @an.render_locals
        # Partials rendered from inside a template carry their locals in the
        # template, not a controller. Compile every view and scan the generated
        # Ruby for `view`/`render` calls so those partials get their locals.
        @an.view_files.each do |path|
          engine = Erubi::Engine.new(File.read(path), bufvar: "@_out_buf", escape: @an.view_escape?, escapefunc: "h")
          @an.collect_render_locals(engine.src, locals_by_template)
        end
        out                = +"# frozen_string_literal: true\n\nmodule Views\n"

        layout_files = @an.view_files.select { |path| layout_file?(path) }
        views        = @an.view_files - layout_files
        views.each do |path|
          template = template_name(path)
          locals   = locals_by_template[template] || []
          out << compile_view(path, "view_#{template.tr('/', '_')}", locals, nil)
          out << "\n"
        end

        layout_files.each do |path|
          out << compile_view(path, "layout_view_#{template_name(path).tr('/', '_')}", [], "content")
          out << "\n"
        end

        out << render_view_method(views, layouts: layout_files, default_layout: default_layout(layout_files))

        out << "end\n"
        File.write(File.join(@out, "generated", "views.rb"), out)
      end

      # A layout is a template under `views/layouts/` or `views/layout.erb`.
      # (`views/admin/products/layout_edit.erb` is a normal view.)
      def layout_file?(path)
        path.include?("/views/layouts/") || File.basename(path) == "layout.erb"
      end

      # The layout applied when a `render`/`view` call does not pass one: the
      # app's `plugin :render, layout: ...`, or a bare `views/layout.erb`.
      def default_layout(layout_files)
        return @an.view_layout if @an.view_layout

        legacy = layout_files.find { |path| File.basename(path) == "layout.erb" }
        legacy ? template_name(legacy) : nil
      end

      # Spinel's parser rejects a `case` with no `when` branch, so an app that
      # ships only a layout (no module views yet) gets an empty inner body
      # instead. Layouts are selected by name (nil => the app default,
      # `false` => none), which is how Izen's `layout:` option is passed.
      def render_view_method(views, layouts:, default_layout:)
        out = +"  def view(template, locals: {}, layout: nil)\n"
        # Rendering a template assigns `@_out_buf` as it runs. A partial invoked
        # from inside a helper (`view("x", layout: false)`) would otherwise
        # clobber the caller's buffer, so save it around the whole call and
        # return the captured output instead of leaving `@_out_buf` swapped.
        out << "    saved = @_out_buf\n"
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
        out << "    result =\n"
        if layouts.empty?
          out << "      inner\n"
        else
          out << "      if layout == false\n"
          out << "        inner\n"
          out << "      else\n"
          out << "        name = layout || #{default_layout.inspect}\n"
          out << "        case name\n"
          layouts.each do |path|
            template = template_name(path)
            out << "        when #{template.inspect} then layout_view_#{template.tr('/', '_')}(inner)\n"
          end
          out << "        else inner\n"
          out << "        end\n"
          out << "      end\n"
        end
        out << "    @_out_buf = saved\n"
        out << "    result\n"
        out << "  end\n"
        out
      end

      def compile_view(path, method_name, locals, replace_yield)
        source = File.read(path)
        source = source.gsub("yield", replace_yield) if replace_yield
        # Match Tilt::ErubiTemplate (what Izen uses through Roda's :render
        # plugin): the engine's escaping follows the app's `escape` option.
        # With `escape: true`, `<%=` escapes through the render scope's `h` and
        # `<%==` emits raw HTML.
        # Roda/Tilt compile templates against `@_out_buf` (the render plugin
        # sets `outvar: "@_out_buf"`), so app helpers that manipulate the
        # output buffer (`capture`, `form_tag`) must see the same variable.
        engine = Erubi::Engine.new(source, bufvar: "@_out_buf", escape: @an.view_escape?, escapefunc: "h")

        out = +"  def #{method_name}(#{replace_yield ? "content" : "locals"})\n"
        # Izen's controller#render exposes locals BOTH as locals and as
        # instance variables (so views written for either style work). The
        # ivar is only overwritten when the key is present: a view rendered as
        # a partial (`view("x", layout: false)`) must keep the ivars its parent
        # already set, instead of resetting them to nil.
        locals.each do |name|
          out << "    #{name} = locals[:#{name}]\n"
          out << "    @#{name} = locals[:#{name}] if locals.key?(:#{name})\n"
        end
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

        (@an.controller_files + @an.repository_files + @an.support_files).sort.each do |path|
          relative = path.sub("#{@source}/", "").sub(/\.rb\z/, "")
          out << "require_relative \"../#{relative}\"\n"
        end
        out << "require_relative \"repositories\"\n"
        # App helper modules the source App `include`s are re-opened onto the
        # generated AppHelpers (which the generated App includes); Spinel does
        # not dispatch them through method_missing, so they must be in the
        # ancestor chain for the controller delegators to resolve.
        includes = @an.app_includes.reject { |name| name == "AppHelpers" }
        unless includes.empty?
          out << "\nmodule AppHelpers\n"
          includes.each { |name| out << "  include #{name}\n" }
          out << "end\n"
        end
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
        # The source app.rb starts the scheduler in-process; the native boot has
        # no `app.rb` top level, so replicate it here when the app ships one.
        boot = File.file?(
          File.join(
            @source,
            "app",
            "scheduler.rb"
          )
        ) ? "Scheduler.start unless Database.env == \"test\"\n" : ""
        File.write(File.join(@out, "bin", "serve.rb"), <<~RUBY)
          # frozen_string_literal: true

          require_relative "../app"
          require_relative "../runtime/server"

          Database.migrate!   # idempotent; adopts an existing database
          #{boot}Server.run
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

      def write_dockerignore
        File.write(File.join(@out, ".dockerignore"), Izen::Cli::NativeAssets.dockerignore)
      end

      # The Dockerfile and the native Kamal config are project artifacts (they
      # live at the project root, next to the CRuby config), not generated build
      # output, so they survive `rm -rf native/` and can be versioned. `izen new`
      # scaffolds them; here we fill in defaults for projects created before
      # they existed. Never clobber a file the user may have edited.
      def ensure_native_assets
        write_if_missing(File.join(@source, "Dockerfile.native"), Izen::Cli::NativeAssets.dockerfile)
        write_if_missing(
          File.join(@source, "config", "deploy.native.yml"),
          Izen::Cli::Kamal.deploy_native_yml(@name, context: context_path)
        )
        write_if_missing(File.join(@source, ".kamal", "secrets-common"), Izen::Cli::Kamal.secrets(@name))
      end

      # The `native/` build context as Kamal should see it: relative to the
      # project root (where `kamal` is run) when the output lives inside it.
      def context_path
        return @out.sub("#{@source}/", "") if @out.start_with?("#{@source}/")

        @out
      end

      def write_if_missing(path, content)
        return if File.file?(path)

        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, content)
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
