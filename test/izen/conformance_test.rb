# frozen_string_literal: true

require_relative "../test_helper"
require "izen/native"
require "izen/native/conformance"

# Differential tests: replay one stateful scenario sequence against the source
# Roda app, the generated project on CRuby and (when opted in) the compiled
# Spinel binary, then assert their observable responses are identical.
#
#   rake test                    # source vs generated-on-CRuby (fast, no Spinel)
#   rake native:conformance      # also builds and compares the native binary
#
# See Izen::Native::Conformance for what is compared and what is deliberately
# not (cookie names/values, transport headers).
class ConformanceTest < Minitest::Test
  include TestSupport::Scaffold

  # A create → read → update → validate → delete walk through the scaffolded
  # `widget` module, plus the root page and a 404.
  SCENARIOS = [
    { "id" => "root",        "method" => "GET",  "path" => "/" },
    { "id" => "index-empty", "method" => "GET",  "path" => "/widgets" },
    { "id" => "new",         "method" => "GET",  "path" => "/widgets/new" },
    {
      "id" => "create", "method" => "POST", "path" => "/widgets",
      "body" => "name=Bolt&price=42&description=x",
      "headers" => { "content-type" => "application/x-www-form-urlencoded" }
    },
    { "id" => "index-one",   "method" => "GET",  "path" => "/widgets" },
    { "id" => "show",        "method" => "GET",  "path" => "/widgets/1" },
    {
      "id" => "update", "method" => "POST", "path" => "/widgets/1",
      "body" => "_method=put&name=Bolt+2&price=43&description=y",
      "headers" => { "content-type" => "application/x-www-form-urlencoded" }
    },
    { "id" => "index-two", "method" => "GET", "path" => "/widgets" },
    {
      "id" => "invalid", "method" => "POST", "path" => "/widgets",
      "body" => "name=&price=1&description=z",
      "headers" => { "content-type" => "application/x-www-form-urlencoded" }
    },
    {
      "id" => "destroy", "method" => "POST", "path" => "/widgets/1",
      "body" => "_method=delete",
      "headers" => { "content-type" => "application/x-www-form-urlencoded" }
    },
    { "id" => "index-none",  "method" => "GET",  "path" => "/widgets" },
    { "id" => "not-found",   "method" => "GET",  "path" => "/nope" }
  ].freeze

  def test_source_and_generated_cruby_agree
    Dir.mktmpdir("izen-conformance") do |dir|
      source    = scaffold_project(dir)
      generated = File.join(dir, "cruby")

      Izen::Native::Generator.new(source, generated).run

      reference = Izen::Native::Conformance.rack(source, scenarios: SCENARIOS)
      actual    = Izen::Native::Conformance.cruby(generated, scenarios: SCENARIOS)
      diffs     = Izen::Native::Conformance.differences(reference, actual)

      assert_baseline(reference)
      assert_empty diffs, "source vs generated (CRuby) diverged:\n#{diffs.join("\n\n")}"
    end
  end

  # Opt-in: needs Spinel on PATH (or SPINEL_BIN) and takes as long as a build.
  def test_generated_cruby_and_native_binary_agree
    unless ENV["IZEN_CONFORMANCE_BUILD"]
      skip "set IZEN_CONFORMANCE_BUILD=1 (or run `rake native:conformance`) to build and compare the native binary"
    end

    Dir.mktmpdir("izen-conformance") do |dir|
      source = scaffold_project(dir)
      cruby  = File.join(dir, "cruby")
      native = File.join(dir, "native")

      Izen::Native::Generator.new(source, cruby).run
      binary = Izen::Native::Builder.new(source: source, out: native).build

      reference = Izen::Native::Conformance.cruby(cruby, scenarios: SCENARIOS)
      actual    = Izen::Native::Conformance.binary(binary, native, scenarios: SCENARIOS)
      diffs     = Izen::Native::Conformance.differences(reference, actual)

      assert_baseline(reference)
      assert_empty diffs, "generated (CRuby) vs native binary diverged:\n#{diffs.join("\n\n")}"
    end
  end

  def test_load_scenarios_falls_back_to_the_defaults_when_absent
    scenarios = Izen::Native::Conformance.load_scenarios(File.join(Dir.mktmpdir, "native_scenarios.rb"))

    assert_equal Izen::Native::Conformance::DEFAULT_SCENARIOS, scenarios
  end

  def test_load_scenarios_reads_the_scaffolded_module
    Dir.mktmpdir("izen-scenarios") do |dir|
      path = File.join(dir, "native_scenarios.rb")
      File.write(path, <<~RUBY)
        module NativeScenarios
          SCENARIOS = [ { "id" => "health", "method" => "GET", "path" => "/health" } ].freeze
        end
      RUBY

      scenarios = Izen::Native::Conformance.load_scenarios(path)

      assert_equal "health", scenarios.first["id"]
    end
  end

  def test_differences_reports_the_mismatched_fields
    expected = [ { "id" => "a", "status" => 200, "location" => nil, "body" => "hi" } ]
    actual   = [ { "id" => "a", "status" => 404, "location" => "/x", "body" => "nope" } ]

    report = Izen::Native::Conformance.differences(expected, actual).join("\n")

    assert_includes report, "status"
    assert_includes report, "location"
    assert_includes report, "body"
  end

  private

  # Guards against a scenario that stops exercising the app: if the reference
  # itself is a wall of identical empty responses, parity is meaningless.
  def assert_baseline(responses)
    by_id = responses.to_h { |response| [ response["id"], response ] }

    assert_equal 302, by_id["create"]["status"]
    assert_equal "/widgets", by_id["create"]["location"]
    assert_includes by_id["index-one"]["body"], "Bolt"
    assert_includes by_id["index-two"]["body"], "Bolt 2"
    assert_includes by_id["invalid"]["body"], "wajib diisi"
    assert_equal 404, by_id["not-found"]["status"]
    assert_equal "", by_id["not-found"]["body"]
  end
end
