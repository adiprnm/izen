# frozen_string_literal: true

require_relative "../test_helper"
require "tmpdir"

class ConfigTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("izen-config")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def write(name, content)
    path = File.join(@dir, name)
    File.write(path, content)
    path
  end

  def test_loads_plain_yaml
    path = write("plain.yml", { "development" => { "path" => "storage/dev.db" } }.to_yaml)

    assert_equal({ "development" => { "path" => "storage/dev.db" } }, Izen::Config.load_yaml(path))
  end

  def test_interpolates_environment_variables
    path               = write("erb.yml", <<~YAML)
      production:
        bucket: "<%= ENV["TEST_BUCKET"] %>"
        region: "<%= ENV.fetch("TEST_REGION", "auto") %>"
    YAML
    ENV["TEST_BUCKET"] = "from-env"

    parsed = Izen::Config.load_yaml(path)

    assert_equal "from-env", parsed.dig("production", "bucket")
    assert_equal "auto", parsed.dig("production", "region")
  ensure
    ENV.delete("TEST_BUCKET")
  end

  def test_wraps_yaml_errors
    path = write("broken.yml", "development: [unclosed\n")

    assert_raises(Izen::Config::Error) { Izen::Config.load_yaml(path) }
  end

  def test_wraps_erb_errors
    path = write("bad-erb.yml", "x: <%= undefined_helper %>\n")

    assert_raises(Izen::Config::Error) { Izen::Config.load_yaml(path) }
  end
end
