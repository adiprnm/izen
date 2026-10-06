# frozen_string_literal: true

require_relative "../test_helper"
require "rack/test"

class RateLimitHelperTest < Minitest::Test
  class App < Izen::Application
    route do |r|
      r.get("limited") do
        rate_limit!("helper", limit: 1, window: 60)
        "ok"
      end
    end
  end

  include Rack::Test::Methods

  def app
    App
  end

  def setup
    Izen::RateLimit.ensure_table!
    Izen::RateLimit.clear("helper:127.0.0.1")
  end

  def teardown
    Izen::RateLimit.clear("helper:127.0.0.1")
  end

  def test_allows_requests_within_the_limit
    get "/limited"

    assert last_response.ok?
    assert_equal "ok", last_response.body
  end

  def test_halts_with_429_when_the_limit_is_exhausted
    get "/limited"
    get "/limited"

    assert_equal 429, last_response.status
    assert_equal "60", last_response.headers["retry-after"]
    assert_equal "Too Many Requests", last_response.body
  end
end
