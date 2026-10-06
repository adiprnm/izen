# frozen_string_literal: true

require_relative "../test_helper"

class SlugTest < Minitest::Test
  def test_generate_lowercases_and_dasherizes
    assert_equal "kaos-polos-l", Izen::Slug.generate("Kaos Polos   L!")
    assert_equal "a-b", Izen::Slug.generate("A_B")
  end

  def test_generate_falls_back_to_item
    assert_equal "item", Izen::Slug.generate("!!!")
    assert_equal "item", Izen::Slug.generate(nil)
  end

  def test_unique_appends_a_suffix_until_free
    assert_equal "kaos", Izen::Slug.unique("Kaos", [])
    assert_equal "kaos-2", Izen::Slug.unique("Kaos", [ "kaos" ])
    assert_equal "kaos-3", Izen::Slug.unique("Kaos", [ "kaos", "kaos-2" ])
  end

  def test_unique_ignores_the_records_own_slug
    assert_equal "kaos", Izen::Slug.unique("Kaos", [ "kaos" ], ignore: "kaos")
  end
end
