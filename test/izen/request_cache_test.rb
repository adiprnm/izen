# frozen_string_literal: true

require_relative "../test_helper"

class RequestCacheTest < Minitest::Test
  def teardown
    Izen::RequestCache.end!
  end

  def test_outside_a_request_fetch_just_yields
    calls = 0

    assert_equal "a", Izen::RequestCache.fetch("k") { calls += 1; "a" }
    assert_equal "a", Izen::RequestCache.fetch("k") { calls += 1; "a" }
    assert_equal 2, calls
  end

  def test_memoizes_within_a_request
    Izen::RequestCache.begin!
    calls = 0

    assert_equal "a", Izen::RequestCache.fetch("k") { calls += 1; "a" }
    assert_equal "a", Izen::RequestCache.fetch("k") { calls += 1; "b" }
    assert_equal 1, calls
  end

  def test_clear_drops_a_key_or_everything
    Izen::RequestCache.begin!
    Izen::RequestCache.fetch("a") { 1 }
    Izen::RequestCache.fetch("b") { 2 }

    Izen::RequestCache.clear("a")

    assert_equal 2, Izen::RequestCache.fetch("a") { 2 }
    assert_equal 2, Izen::RequestCache.fetch("b") { 99 }

    Izen::RequestCache.clear
    assert_equal 3, Izen::RequestCache.fetch("b") { 3 }
  end

  def test_end_closes_the_cache
    Izen::RequestCache.begin!
    Izen::RequestCache.fetch("k") { "a" }
    Izen::RequestCache.end!

    assert_equal "b", Izen::RequestCache.fetch("k") { "b" }
  end
end
