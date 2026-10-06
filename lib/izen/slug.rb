# frozen_string_literal: true

module Izen
  # URL-friendly slugs for any record that needs one (posts, products, ...).
  #
  # Dependency-free; callers are responsible for checking uniqueness against
  # their own table (see #unique, which appends -2, -3, ... until the candidate
  # is free).
  #
  #   Izen::Slug.generate("Kaos Polos L!")            # => "kaos-polos-l"
  #   Izen::Slug.unique("Kaos", ["kaos", "kaos-2"])   # => "kaos-3"
  module Slug
    module_function

    # "Kaos Polos   L!" -> "kaos-polos-l". Falls back to "item" for input that
    # has no usable characters (e.g. all punctuation).
    def generate(text)
      slug = text.to_s.downcase.strip
      slug = slug.gsub(/[^a-z0-9\s_-]/, "")
      slug = slug.tr("_", "-").gsub(/[\s-]+/, "-").gsub(/\A-+|-+\z/, "")
      slug.empty? ? "item" : slug
    end

    # Returns a slug derived from +text+ that does not collide with +taken+.
    # Pass +ignore+ (a slug already owned by the record being edited) so it is
    # not treated as a collision with itself.
    def unique(text, taken, ignore: nil)
      base      = generate(text)
      used      = Array(taken).map(&:to_s) - [ ignore.to_s ]
      candidate = base
      suffix    = 2

      while used.include?(candidate)
        candidate = "#{base}-#{suffix}"
        suffix   += 1
      end

      candidate
    end
  end
end
