# frozen_string_literal: true

require_relative "../../test_helper"

class ModelTest < Minitest::Test
  class Widget < Izen::Base::Model
    attribute :id,    Integer, required: false
    attribute :name,  String
    attribute :price, Integer, required: false, default: 0
  end

  def test_builds_from_a_hash_and_coerces
    widget = Widget.new("id" => "1", name: "Kopi", price: "25000")

    assert_equal 1, widget.id
    assert_equal "Kopi", widget.name
    assert_equal 25_000, widget.price
  end

  def test_applies_defaults
    assert_equal 0, Widget.new(name: "Teh").price
  end

  def test_raises_when_a_required_attribute_is_missing
    assert_raises(ArgumentError) { Widget.new }
  end

  def test_strict_false_skips_coercion_and_required_checks
    widget = Widget.new({ name: "Kopi", price: "abc" }, strict: false)

    assert_equal "abc", widget.price
  end

  def test_equality_and_to_h
    assert_equal Widget.new(name: "A"), Widget.new(name: "A")
    assert_equal({ id: nil, name: "A", price: 0 }, Widget.new(name: "A").to_h)
  end
end
