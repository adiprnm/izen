# frozen_string_literal: true

require_relative "../test_helper"
require "rack/test"

class ApplicationTest < Minitest::Test
  class App < Izen::Application
    route do |r|
      r.root { render(inline: "hello") }

      r.get("session") do
        session["seen"] = true
        "signed in"
      end
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
    assert_equal File.join(Izen.root, "views"), App.opts[:render][:views]
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
end
