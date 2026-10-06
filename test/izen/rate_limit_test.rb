# frozen_string_literal: true

require_relative "../test_helper"

class RateLimitTest < TestSupport::DatabaseTest
  def setup
    super
    Izen::RateLimit.ensure_table!
  end

  def test_allows_up_to_the_limit_then_denies
    3.times { assert Izen::RateLimit.allow?("k", limit: 3, window: 60) }

    refute Izen::RateLimit.allow?("k", limit: 3, window: 60)
  end

  def test_a_new_window_resets_the_counter
    now = Time.now.utc

    assert Izen::RateLimit.allow?("k", limit: 1, window: 60, now: now)
    refute Izen::RateLimit.allow?("k", limit: 1, window: 60, now: now + 1)
    assert Izen::RateLimit.allow?("k", limit: 1, window: 60, now: now + 61)
  end

  def test_keys_are_independent
    assert Izen::RateLimit.allow?("a", limit: 1, window: 60)
    assert Izen::RateLimit.allow?("b", limit: 1, window: 60)
  end

  def test_count_and_clear
    Izen::RateLimit.allow?("k", limit: 5, window: 60)
    Izen::RateLimit.allow?("k", limit: 5, window: 60)

    assert_equal 2, Izen::RateLimit.count("k")

    Izen::RateLimit.clear("k")

    assert_equal 0, Izen::RateLimit.count("k")
  end
end
