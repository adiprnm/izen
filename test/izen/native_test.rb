# frozen_string_literal: true

require_relative "../test_helper"
require "rbconfig"
require "izen/native"

# The generated Spinel project reopens top-level constants (`App`, `Base`,
# `Rack::Utils`, `SecureRandom`, ...), so it is exercised in a subprocess
# instead of inside the test process.
class NativeTest < Minitest::Test
  DRIVER = <<~'RUBY'
    # frozen_string_literal: true
    ENV["APP_ENV"] = "test"
    root = ARGV[0]
    Dir.chdir(root)
    require File.join(root, "app.rb")
    Database.migrate!

    def req(method, path, query = "", body = "", headers = {})
      App.new.call(Request.new(method, path, query, body, headers))
    end

    def check(label, condition)
      puts "#{condition ? 'ok' : 'FAIL'} #{label}"
      exit 1 unless condition
    end

    form = { "content-type" => "application/x-www-form-urlencoded" }

    check "root",            req("GET", "/").body.include?("Hello from Demo")
    index = req("GET", "/widgets").body
    check "index",           index.include?("Tambah data")
    check "layout raw",      index.include?("<h1>Widget</h1>")
    check "layout escaped",  !index.include?("&lt;h1&gt;")
    check "new form",        req("GET", "/widgets/new").status == 200
    check "create redirect", req("POST", "/widgets", "", "name=Bolt&price=42&description=x", form).status == 302
    check "list has row",    req("GET", "/widgets").body.include?("Bolt")
    check "show",            req("GET", "/widgets/1").body.include?("42")
    check "update",          req("POST", "/widgets/1", "", "_method=put&name=Bolt+2&price=43&description=y", form).status == 302
    check "updated",         req("GET", "/widgets").body.include?("Bolt 2")
    check "validation",      req("POST", "/widgets", "", "name=&price=1&description=z", form).body.include?("wajib diisi")
    check "delete",          req("POST", "/widgets/1", "", "_method=delete", form).status == 302
    check "deleted",         !req("GET", "/widgets").body.include?("Bolt")
    check "not found",       req("GET", "/nope").status == 404

    puts "ALL OK"
  RUBY

  # Minimal app with no module views: only the root route and the layout.
  PLAIN_DRIVER = <<~'RUBY'
    # frozen_string_literal: true
    ENV["APP_ENV"] = "test"
    root = ARGV[0]
    Dir.chdir(root)
    require File.join(root, "app.rb")
    Database.migrate!

    body = App.new.call(Request.new("GET", "/", "", "", {})).body
    puts(body.include?("Hello from Demo") ? "ALL OK" : "FAIL")
  RUBY

  def test_generates_a_runnable_project_from_a_scaffolded_app
    Dir.mktmpdir("izen-native") do |dir|
      source = scaffold_project(dir)
      out    = File.join(dir, "native")

      Izen::Native::Generator.new(source, out).run

      assert File.file?(File.join(out, "app.rb"))
      assert File.file?(File.join(out, "spin.toml"))
      assert File.file?(File.join(out, "generated", "routes.rb"))
      assert File.file?(File.join(out, "spinel", "sqlite_shim.c"))
      assert File.file?(File.join(out, "db", "schema.sql"))
      assert File.file?(File.join(out, "config", "deploy.yml"))
      assert File.file?(File.join(out, ".kamal", "secrets"))

      assert_includes File.read(File.join(out, "generated", "models.rb")), "class Model < Base::Model"
      assert_includes File.read(File.join(out, "generated", "routes.rb")), 'r.segments[0] == "widgets"'

      output = run_driver(out)
      assert_includes output, "ALL OK", "driver output:\n#{output}"
    end
  end

  def test_spinel_target_swaps_the_database_adapter
    Dir.mktmpdir("izen-native") do |dir|
      source = scaffold_project(dir)
      out    = File.join(dir, "native")

      Izen::Native::Generator.new(source, out, spinel: true).run

      assert_includes File.read(File.join(out, "app.rb")), 'require_relative "spinel/database_spinel"'
      assert File.file?(File.join(out, "spinel", "sqlite_ffi.rb"))
    end
  end

  def test_refuses_to_overwrite_the_source_app
    Dir.mktmpdir("izen-native") do |dir|
      source = scaffold_project(dir)

      assert_raises(ArgumentError) do
        Izen::Native::Generator.new(source, source).run
      end

      assert File.file?(File.join(source, "app.rb"))
    end
  end

  def test_generates_a_default_kamal_config_when_the_source_has_none
    Dir.mktmpdir("izen-native") do |dir|
      source = scaffold_project(dir)
      out    = File.join(dir, "native")
      FileUtils.rm_f(File.join(source, "config", "deploy.yml"))
      FileUtils.rm_rf(File.join(source, ".kamal"))

      Izen::Native::Generator.new(source, out).run

      deploy = File.read(File.join(out, "config", "deploy.yml"))
      assert_includes deploy, "service: demo"
      assert_includes deploy, "app_port: 3000"
      assert_includes deploy, "demo_storage:/app/storage"

      assert_includes File.read(File.join(out, ".kamal", "secrets")), "SESSION_SECRET=$SESSION_SECRET"
    end
  end

  def test_copies_and_patches_the_source_kamal_config
    Dir.mktmpdir("izen-native") do |dir|
      source = scaffold_project(dir)
      out    = File.join(dir, "native")
      File.write(File.join(source, "config", "deploy.yml"), <<~YAML)
        service: custom
        servers:
          web:
            - 10.0.0.1
        proxy:
          ssl: true
          host: custom.example.com
      YAML

      Izen::Native::Generator.new(source, out).run

      deploy = File.read(File.join(out, "config", "deploy.yml"))
      assert_includes deploy, "service: custom"
      assert_includes deploy, "10.0.0.1"
      assert_includes deploy, "custom.example.com"
      assert_includes deploy, "  app_port: 3000"
    end
  end

  def test_generates_a_plain_app_without_module_views
    Dir.mktmpdir("izen-native") do |dir|
      source = scaffold_project(dir, with_module: false)
      out    = File.join(dir, "native")

      Izen::Native::Generator.new(source, out).run

      # Spinel rejects a `case` with no `when` branch, so an app with only a
      # layout must not get one.
      views = File.read(File.join(out, "generated", "views.rb"))
      assert_includes views, 'inner = ""'
      refute_includes views, "case template"

      output = run_driver(out, PLAIN_DRIVER)
      assert_includes output, "ALL OK", "driver output:\n#{output}"
    end
  end

  def test_compiles_string_and_multi_segment_route_params
    Dir.mktmpdir("izen-native") do |dir|
      source = scaffold_project(dir, with_module: false)
      app_rb = File.join(source, "app.rb")
      routes = <<~RUBY
        r.on "pages" do
          r.is String do |slug|
            "page:\#{slug}"
          end
        end
        r.get("download", String) do |token|
          "token:\#{token}"
        end
      RUBY
      File.write(app_rb, File.read(app_rb).sub("    # cli:module-routes\n", routes))
      out    = File.join(dir, "native")

      Izen::Native::Generator.new(source, out).run

      driver = <<~'RUBY'
        ENV["APP_ENV"] = "test"
        root = ARGV[0]
        Dir.chdir(root)
        require File.join(root, "app.rb")
        Database.migrate!

        page  = App.new.call(Request.new("GET", "/pages/hello", "", "", {})).body
        token = App.new.call(Request.new("GET", "/download/abc123", "", "", {})).body
        puts(page.include?("page:hello") ? "ok page" : "FAIL page: #{page.inspect}")
        puts(token.include?("token:abc123") ? "ok token" : "FAIL token: #{token.inspect}")
        puts "ALL OK"
      RUBY

      output = run_driver(out, driver)
      assert_includes output, "ok page", "driver output:\n#{output}"
      assert_includes output, "ok token", "driver output:\n#{output}"
      assert_includes output, "ALL OK", "driver output:\n#{output}"
    end
  end

  def test_builder_reports_a_missing_spin_executable
    Dir.mktmpdir("izen-native") do |dir|
      source  = scaffold_project(dir)
      builder = Izen::Native::Builder.new(source: source, out: File.join(dir, "native"), spinel_bin: dir)

      error = assert_raises(Izen::Native::SpinNotFound) { builder.build }
      assert_includes error.message, "no spin executable"
    end
  end

  def test_request_parses_multipart_form_data
    request = File.expand_path("../../lib/izen/native/runtime/request.rb", __dir__)
    driver  = File.join(Dir.mktmpdir("izen-multipart"), "driver.rb")
    File.write(driver, MULTIPART_DRIVER.sub("REQUEST_PATH", request))

    output = IO.popen([ RbConfig.ruby, driver ], err: [ :child, :out ], &:read)
    assert_includes output, "ALL OK", "driver output:\n#{output}"
  end

  def test_request_exposes_content_type
    request = File.expand_path("../../lib/izen/native/runtime/request.rb", __dir__)
    driver  = File.join(Dir.mktmpdir("izen-content-type"), "driver.rb")
    File.write(driver, CONTENT_TYPE_DRIVER.sub("REQUEST_PATH", request))

    output = IO.popen([ RbConfig.ruby, driver ], err: [ :child, :out ], &:read)
    assert_includes output, "ALL OK", "driver output:\n#{output}"
  end

  def test_render_locals_follow_hash_variables_and_helper_returns
    Dir.mktmpdir("izen-locals") do |dir|
      FileUtils.mkdir_p(File.join(dir, "app", "admin", "dashboard"))
      FileUtils.mkdir_p(File.join(dir, "app", "settings"))

      File.write(File.join(dir, "app", "admin", "dashboard", "controller.rb"), <<~RUBY)
        module Admin
          module Dashboard
            class Controller
              def index
                locals = { ranges: [], revenue: 1 }
                locals[:chart_labels] = []
                render("admin/dashboard/index", locals)
              end
            end
          end
        end
      RUBY

      File.write(File.join(dir, "app", "settings", "controller.rb"), <<~RUBY)
        module Settings
          class Controller
            def edit
              render("settings/edit", settings_locals)
            end

            def settings_locals
              { active_tab: "site", site_name: Setting.get("site_name") }
            end
          end
        end
      RUBY

      locals = Izen::Native::Analyzer.new(dir).render_locals

      assert_equal %w[ranges revenue chart_labels], locals["admin/dashboard/index"]
      assert_equal %w[active_tab site_name], locals["settings/edit"]
    end
  end

  def test_views_only_overwrite_ivars_whose_locals_are_present
    Dir.mktmpdir("izen-native") do |dir|
      source = scaffold_project(dir)
      out    = File.join(dir, "native")

      Izen::Native::Generator.new(source, out).run

      views = File.read(File.join(out, "generated", "views.rb"))
      assert_includes views, "if locals.key?(", "parent ivars must survive a partial render"
    end
  end

  private

  # Exercises the runtime Request directly: a multipart form must expose
  # `_csrf`, honour `_method` and keep file parts (the settings-save bug).
  MULTIPART_DRIVER = <<~'RUBY'
    require "REQUEST_PATH"

    boundary = "----TestBoundary123"
    body = [
      "--#{boundary}",
      'Content-Disposition: form-data; name="_csrf"',
      "",
      "tok123",
      "--#{boundary}",
      'Content-Disposition: form-data; name="_method"',
      "",
      "patch",
      "--#{boundary}",
      'Content-Disposition: form-data; name="channels[]"',
      "",
      "qris",
      "--#{boundary}",
      'Content-Disposition: form-data; name="channels[]"',
      "",
      "va",
      "--#{boundary}",
      'Content-Disposition: form-data; name="qris_image"; filename=""',
      "Content-Type: application/octet-stream",
      "",
      "",
      "--#{boundary}",
      'Content-Disposition: form-data; name="site_favicon"; filename="logo.png"',
      "Content-Type: image/png",
      "",
      "PNGDATA",
      "--#{boundary}--",
      ""
    ].join("\r\n")

    headers = { "content-type" => "multipart/form-data; boundary=#{boundary}" }
    req     = Request.new("POST", "/admin/settings", "", body, headers)
    params  = req.params
    file    = params["site_favicon"]

    def check(label, condition)
      puts "#{condition ? 'ok' : 'FAIL'} #{label}"
      exit 1 unless condition
    end

    check "csrf",        params["_csrf"] == "tok123"
    check "method param", params["_method"] == "patch"
    check "method swap",  req.request_method == "PATCH"
    check "array",        params["channels"] == %w[qris va]
    check "blank file",   !params.key?("qris_image")
    check "filename",     file.is_a?(Hash) && file[:filename] == "logo.png"
    check "type",         file.is_a?(Hash) && file[:type] == "image/png"
    check "content",      file.is_a?(Hash) && file[:tempfile].read == "PNGDATA"
    puts "ALL OK"
  RUBY

  # A raw-body upload reads `request.content_type` (the full header, like Rack)
  # to pick the MIME it validates and converts; `media_type` drops parameters.
  CONTENT_TYPE_DRIVER = <<~'RUBY'
    require "REQUEST_PATH"

    def check(label, condition)
      puts "#{condition ? 'ok' : 'FAIL'} #{label}"
      exit 1 unless condition
    end

    multipart = Request.new("PUT", "/uploads/proxy/x/y", "", "", { "content-type" => "multipart/form-data; boundary=xyz" })
    json      = Request.new("POST", "/uploads/direct_upload", "", "", { "content-type" => "application/json" })
    blank     = Request.new("GET", "/", "", "", {})

    check "content_type keeps params", multipart.content_type == "multipart/form-data; boundary=xyz"
    check "media_type drops params",  multipart.media_type == "multipart/form-data"
    check "content_type json",         json.content_type == "application/json"
    check "content_type nil",          blank.content_type.nil?
    puts "ALL OK"
  RUBY

  # Builds a minimal Izen app with `izen new` (+ a module unless disabled).
  def scaffold_project(dir, with_module: true)
    previous  = Izen.root
    Izen.root = dir

    quiet { Izen::Cli.run([ "new", "demo" ]) }
    project = File.join(dir, "demo")

    if with_module
      Izen.root = project
      quiet { Izen::Cli.run([ "module", "new", "widget", "name:string", "price:integer", "description:text" ]) }
    end

    project
  ensure
    Izen.root = previous
  end

  def run_driver(out, source = DRIVER)
    driver = File.join(out, "..", "driver.rb")
    File.write(driver, source)
    IO.popen([ RbConfig.ruby, driver, out ], chdir: out, err: [ :child, :out ], &:read)
  end

  def quiet
    original = $stdout
    $stdout  = StringIO.new
    yield
  ensure
    $stdout = original
  end
end
