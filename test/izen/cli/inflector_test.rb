# frozen_string_literal: true

require_relative "../../test_helper"

class InflectorTest < Minitest::Test
  def test_pluralizes_regular_nouns
    assert_equal "posts", Izen::Cli::Inflector.pluralize("post")
    assert_equal "users", Izen::Cli::Inflector.pluralize("user")
  end

  def test_pluralizes_sibilants_with_es
    assert_equal "boxes",    Izen::Cli::Inflector.pluralize("box")
    assert_equal "churches", Izen::Cli::Inflector.pluralize("church")
    assert_equal "dishes",   Izen::Cli::Inflector.pluralize("dish")
    assert_equal "buzzes",   Izen::Cli::Inflector.pluralize("buzz")
  end

  def test_pluralizes_consonant_y_as_ies
    assert_equal "categories", Izen::Cli::Inflector.pluralize("category")
    assert_equal "boys",       Izen::Cli::Inflector.pluralize("boy")
  end

  def test_pluralizes_irregulars
    assert_equal "people",   Izen::Cli::Inflector.pluralize("person")
    assert_equal "children", Izen::Cli::Inflector.pluralize("child")
  end

  def test_pluralizes_only_the_last_segment_of_a_compound_name
    assert_equal "blog_posts",       Izen::Cli::Inflector.pluralize("blog_post")
    assert_equal "sales_people",     Izen::Cli::Inflector.pluralize("sales_person")
  end

  def test_leaves_uncountable_nouns_alone
    assert_equal "news", Izen::Cli::Inflector.pluralize("news")
  end

  def test_singularize_inverts_pluralize
    %w[post category box church person blog_post].each do |singular|
      assert_equal singular, Izen::Cli::Inflector.singularize(Izen::Cli::Inflector.pluralize(singular))
    end
  end

  def test_singularize_leaves_singular_words_unchanged
    %w[post status address bus gas lens].each do |word|
      assert_equal word, Izen::Cli::Inflector.singularize(word)
    end
  end
end
