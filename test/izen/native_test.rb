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
    check "layout raw",      index.include?("<h1>Widgets</h1>")
    check "layout escaped",  !index.include?("&lt;h1&gt;")
    check "new form",        req("GET", "/widgets/new").status == 200
    check "create redirect", req("POST", "/widgets", "", "name=Bolt&price=42&description=x", form).status == 302
    check "list has row",    req("GET", "/widgets").body.include?("Bolt")
    check "show",            req("GET", "/widgets/1").body.include?("42")
    check "update",          req("POST", "/widgets/1", "", "name=Bolt+2&price=43&description=y", form).status == 302
    check "updated",         req("GET", "/widgets").body.include?("Bolt 2")
    check "validation",      req("POST", "/widgets", "", "name=&price=1&description=z", form).body.include?("wajib diisi")
    check "delete",          req("POST", "/widgets/1/delete").status == 302
    check "deleted",         !req("GET", "/widgets").body.include?("Bolt")
    check "not found",       req("GET", "/nope").status == 404

    puts "ALL OK"
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

  def test_builder_reports_a_missing_spin_executable
    Dir.mktmpdir("izen-native") do |dir|
      source  = scaffold_project(dir)
      builder = Izen::Native::Builder.new(source: source, out: File.join(dir, "native"), spinel_bin: dir)

      error = assert_raises(Izen::Native::SpinNotFound) { builder.build }
      assert_includes error.message, "no spin executable"
    end
  end

  private

  # Builds a minimal Izen app with `izen new` + `izen module new`.
  def scaffold_project(dir)
    previous  = Izen.root
    Izen.root = dir

    quiet { Izen::Cli.run([ "new", "demo" ]) }
    project = File.join(dir, "demo")

    Izen.root = project
    quiet { Izen::Cli.run([ "module", "new", "widgets", "name:string", "price:integer", "description:text" ]) }

    project
  ensure
    Izen.root = previous
  end

  def run_driver(out)
    driver = File.join(out, "..", "driver.rb")
    File.write(driver, DRIVER)
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
