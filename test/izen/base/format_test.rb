# frozen_string_literal: true

require_relative "../../test_helper"

class FormatTest < Minitest::Test
  def test_number_groups_thousands
    assert_equal "65.000", Izen::Base::Format.number(65_000)
    assert_equal "-1.500", Izen::Base::Format.number(-1500)
  end

  def test_money_uses_the_currency_symbol
    assert_equal "Rp65.000", Izen::Base::Format.money(65_000)
  end

  def test_datetime_and_age
    time = Time.utc(2026, 9, 25, 1, 21)

    assert_equal "25 Sep 2026 01:21", Izen::Base::Format.datetime(time)
    assert_equal "2h", Izen::Base::Format.age(time, time + 7200)
    assert_equal "", Izen::Base::Format.age(nil)
  end
end
