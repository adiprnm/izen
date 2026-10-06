# frozen_string_literal: true

require_relative "../../test_helper"
require "rack/test"

class ControllerTest < Minitest::Test
  # Calls an app helper with a keyword argument through Base::Controller's
  # method_missing. Before keyword forwarding was fixed this raised
  # ArgumentError (a positional Hash reached a keyword-only method).
  class KwargsController < Izen::Base::Controller
    def call
      app_helper(preserve: [ "cart" ])
    end
  end

  class App < Izen::Application
    def app_helper(preserve:)
      preserve.join(",")
    end

    route do |r|
      r.root { KwargsController.new(self).call }
    end
  end

  include Rack::Test::Methods

  def app
    App
  end

  def test_method_missing_forwards_keyword_arguments
    get "/"

    assert last_response.ok?
    assert_equal "cart", last_response.body
  end
end
