# frozen_string_literal: true

require_relative "../test_helper"
require "rack/test"
require "stringio"

class AccessLogTest < Minitest::Test
  class App < Izen::Application
    LOG_IO = StringIO.new

    # Capture whatever the access log writes, regardless of level.
    def logger
      Logger.new(LOG_IO)
    end

    route do |r|
      r.root { "ok" }

      r.get("which-logger") { server_logger ? "server" : "app" }
    end
  end

  include Rack::Test::Methods

  def app
    App
  end

  def setup
    App::LOG_IO.truncate(0)
    App::LOG_IO.rewind
    ENV.delete("IZEN_ACCESS_LOG")
  end

  def teardown
    ENV.delete("IZEN_ACCESS_LOG")
  end

  def test_access_log_is_off_by_default
    get "/"

    assert_equal "", App::LOG_IO.string
  end

  def test_access_log_when_enabled
    ENV["IZEN_ACCESS_LOG"] = "1"

    get "/"

    assert_includes App::LOG_IO.string, "[izen] GET / 200"
  end

  def test_access_log_skips_static_assets
    ENV["IZEN_ACCESS_LOG"] = "1"

    get "/assets/application.css"

    assert_equal "", App::LOG_IO.string
  end

  def test_logger_prefers_the_server_logger
    server = Logger.new(StringIO.new)

    get "/which-logger", {}, { "rack.logger" => server }

    assert_equal "server", last_response.body
  end

  def test_logger_falls_back_when_the_server_provides_none
    get "/which-logger"

    assert_equal "app", last_response.body
  end
end
