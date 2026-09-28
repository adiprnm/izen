# frozen_string_literal: true

module Izen
  module Cli
    # Minimal English pluralisation for scaffolding.
    #
    # This is deliberately small — it covers the table and route names an
    # `izen module new` call needs, not the full Active Support inflector.
    # Irregular nouns are listed explicitly; anything unknown falls back to the
    # regular rules.
    #
    #   Inflector.pluralize("post")     # => "posts"
    #   Inflector.pluralize("category") # => "categories"
    #   Inflector.pluralize("blog_post") # => "blog_posts"
    module Inflector
      IRREGULAR = {
        "person" => "people",
        "child"  => "children",
        "man"    => "men",
        "woman"  => "women",
        "tooth"  => "teeth",
        "foot"   => "feet",
        "mouse"  => "mice",
        "goose"  => "geese"
      }.freeze

      UNCOUNTABLE = %w[data equipment information money news series species].freeze

      # Singular words that end in "s" and must not be mistaken for plurals.
      SINGULAR_S = %w[
        address alias analysis apparatus atlas axis basis bonus bus cactus campus
        canvas census chaos class cosmos crisis focus gas glass grass iris lens
        loss process status success thesis virus
      ].freeze

      module_function

      # "post" -> "posts", "category" -> "categories", "box" -> "boxes".
      # Only the last segment of a snake_case name is inflected.
      def pluralize(word)
        word = word.to_s
        return word if word.empty? || UNCOUNTABLE.include?(word)

        if word.include?("_")
          head, _, tail = word.rpartition("_")
          return "#{head}_#{pluralize(tail)}"
        end

        return IRREGULAR[word] if IRREGULAR.key?(word)

        case word
        when /(s|x|z|ch|sh)$/ then "#{word}es"
        when /[^aeiou]y$/     then "#{word[0..-2]}ies"
        when /fe$/            then "#{word[0..-3]}ves"
        when /f$/             then "#{word[0..-2]}ves"
        else "#{word}s"
        end
      end

      # Inverse of `pluralize`, best effort. Returns the word unchanged when it
      # does not look plural, which is what makes it safe as a guard.
      def singularize(word)
        word = word.to_s
        return word if word.empty? || UNCOUNTABLE.include?(word) || SINGULAR_S.include?(word)

        if word.include?("_")
          head, _, tail = word.rpartition("_")
          return "#{head}_#{singularize(tail)}"
        end

        reverse = IRREGULAR.invert
        return reverse[word] if reverse.key?(word)

        case word
        when /ss$/           then word
        when /ies$/          then "#{word[0..-4]}y"
        when /(x|z|ch|sh)es$/ then word.sub(/es$/, "")
        when /ves$/          then word.sub(/ves$/, "f")
        when /s$/            then word[0..-2]
        else word
        end
      end
    end
  end
end
