# frozen_string_literal: true

require_relative "../../test_helper"

class TypesTest < Minitest::Test
  def test_coerces_strings_and_integers
    assert_equal "42", Izen::Base::Types.coerce(42, String)
    assert_equal 42, Izen::Base::Types.coerce("42", Integer)
    assert_equal 1.5, Izen::Base::Types.coerce("1.5", Float)
  end

  def test_coerces_booleans
    assert_equal true, Izen::Base::Types.coerce("1", :boolean)
    assert_equal false, Izen::Base::Types.coerce("0", :boolean)
    assert_raises(Izen::Base::Types::CoercionError) { Izen::Base::Types.coerce("nope", :boolean) }
  end

  def test_parses_time_as_utc_without_offset
    time = Izen::Base::Types.coerce("2026-01-02 03:04:05", Time)

    assert_equal Time.utc(2026, 1, 2, 3, 4, 5), time
    assert_predicate time, :utc?
  end

  def test_keeps_offset_when_present
    assert_equal Time.new(2026, 1, 2, 3, 4, 5, "+07:00"), Izen::Base::Types.coerce("2026-01-02 03:04:05 +07:00", Time)
  end

  def test_valid_predicate
    assert Izen::Base::Types.valid?("42", Integer)
    refute Izen::Base::Types.valid?("x", Integer)
  end
end
