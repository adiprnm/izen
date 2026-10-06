# frozen_string_literal: true

require_relative "../test_helper"
require "rack/test"

class ApplicationTest < Minitest::Test
  class App < Izen::Application
    # Keep the test output clean; the default logger writes the 500 backtrace.
    def logger
      @logger ||= Logger.new(File::NULL)
    end

    route do |r|
      r.root { render(inline: "hello") }

      r.get("session") do
        session["seen"] = true
        "signed in"
      end

      r.get("health") { health }

      r.get("rotate") do
        session["keep"] = "yes"
        session["drop"] = "no"
        rotate_session!(preserve: [ "keep" ])
        "#{session["keep"]}/#{session["drop"].inspect}"
      end

      r.get("cache") do
        first  = Izen::RequestCache.fetch("k") { "v1" }
        second = Izen::RequestCache.fetch("k") { "v2" }
        "#{first}-#{second}"
      end

      r.get("boom") { raise "kaboom" }

      r.put("widgets")    { "put" }
      r.patch("widgets")  { "patch" }
      r.delete("widgets") { "delete" }
    end
  end

  include Rack::Test::Methods

  def app
    App
  end

  def test_inherits_from_roda
    assert_operator Izen::Application, :<, Roda
    assert_operator App, :<, Izen::Application
  end

  def test_anchors_root_and_views_to_the_application_root
    assert_equal Izen.root, App.opts[:root]
    assert_equal File.join(Izen.root, "app"), App.opts[:render][:views]
  end

  def test_derives_the_session_cookie_key_from_the_class_name
    assert_equal "app_session", App.opts[:memory_session][:key]
  end

  def test_serves_requests
    get "/"

    assert last_response.ok?
    assert_equal "hello", last_response.body
  end

  def test_wires_up_flash_and_sessions
    get "/session"

    assert last_response.ok?
    assert_includes last_response.headers["Set-Cookie"].to_s, "app_session"
  end

  def test_enables_the_all_verbs_matchers
    assert App::RodaRequest.method_defined?(:put)
    assert App::RodaRequest.method_defined?(:patch)
    assert App::RodaRequest.method_defined?(:delete)
  end

  def test_serves_real_put_patch_and_delete_requests
    put "/widgets"
    assert last_response.ok?
    assert_equal "put", last_response.body

    patch "/widgets"
    assert last_response.ok?
    assert_equal "patch", last_response.body

    delete "/widgets"
    assert last_response.ok?
    assert_equal "delete", last_response.body
  end

  def test_honors_method_override_from_a_post_form
    post "/widgets", { "_method" => "put" }
    assert last_response.ok?
    assert_equal "put", last_response.body

    post "/widgets", { "_method" => "delete" }
    assert last_response.ok?
    assert_equal "delete", last_response.body
  end

  def test_sets_security_headers
    get "/"

    assert_equal "nosniff", last_response.headers["x-content-type-options"]
    assert_equal "DENY", last_response.headers["x-frame-options"]
    assert_equal "strict-origin-when-cross-origin", last_response.headers["referrer-policy"]
  end

  def test_health_endpoint_reports_ok
    TestSupport.db.execute(
      "CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY, applied_at TEXT)"
    )

    get "/health"

    assert_equal 200, last_response.status
    body = JSON.parse(last_response.body)
    assert_equal "ok", body["status"]
    assert_equal "ok", body["database"]
  end

  def test_unknown_route_is_an_empty_404_without_a_view
    get "/nope"

    assert_equal 404, last_response.status
    assert_equal "", last_response.body
  end

  def test_unknown_route_renders_the_errors_view_when_present
    path = File.join(Izen.root, "app", "errors", "not_found.erb")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "not found here")

    get "/nope"

    assert_equal 404, last_response.status
    assert_equal "not found here", last_response.body
  ensure
    FileUtils.rm_f(path)
  end

  def test_internal_errors_render_a_500
    get "/boom"

    assert_equal 500, last_response.status
  end

  def test_rotate_session_keeps_the_listed_keys
    get "/rotate"

    assert_equal "yes/nil", last_response.body
  end

  def test_request_cache_memoizes_within_a_request
    get "/cache"

    assert_equal "v1-v1", last_response.body
  end
end
