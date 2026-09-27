# frozen_string_literal: true

require_relative "../../test_helper"

class RepositoryTest < TestSupport::DatabaseTest
  def setup
    super
    @repository = TestSupport::Widgets::Repository.new
  end

  def test_create_and_find_round_trips_a_model
    created = @repository.create(TestSupport::Widgets::Model.new(name: "Kopi", price: 25_000))
    found   = @repository.find(created.id)

    assert_instance_of TestSupport::Widgets::Model, found
    assert_equal "Kopi", found.name
    assert_equal 25_000, found.price
  end

  def test_all_returns_models
    @repository.create(TestSupport::Widgets::Model.new(name: "A", price: 1))
    @repository.create(TestSupport::Widgets::Model.new(name: "B", price: 2))

    assert_equal %w[A B], @repository.all.map(&:name)
  end

  def test_model_class_is_resolved_from_the_repository_namespace
    assert_equal TestSupport::Widgets::Model, @repository.model_class
  end

  def test_query_forces_utf8_on_string_params
    @repository.create(TestSupport::Widgets::Model.new(name: "Kopi", price: 1))
    binary = "Kopi".dup.force_encoding(Encoding::ASCII_8BIT)

    assert_equal "Kopi", @repository.find_one("SELECT name FROM widgets WHERE name = ?", [ binary ])[:name]
  end
end
