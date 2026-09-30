# frozen_string_literal: true

require_relative "types"

module Base
  # Attribute-based value object, lowered from `Izen::Base::Model`.
  #
  # The generated subclass declares `self.attributes` and one explicit reader
  # per attribute (Spinel cannot define readers from a runtime-computed name),
  # and values live in a Hash instead of per-instance ivars.
  class Model
    def initialize(values = nil, strict: true, **attributes)
      @strict                                    = strict
      merged                                     = {}
      if values.is_a?(Hash)
        values.each { |key, value| merged[key.to_sym] = value }
      elsif values
        values.to_h.each { |key, value| merged[key.to_sym] = value }
      end
      attributes.each { |key, value| merged[key] = value }

      @attrs = {}
      self.class.attributes.each do |name, spec|
        # A key that is present with a nil value is not "missing" (Izen uses it
        # to render an empty form); only a truly absent, required attribute
        # raises in strict mode.
        present      = merged.key?(name)
        raw          = present ? merged[name] : spec[:default]
        if !present && raw.nil? && spec[:required] && strict
          raise ArgumentError, "missing required attribute :#{name} for #{self.class}"
        end
        value        = (raw.nil? || !strict) ? raw : Types.coerce(raw, spec[:type])
        @attrs[name] = value
      end

      after_initialize
    end

    # Hook for generated subclasses: they mirror each attribute into a real
    # instance variable (Spinel cannot set ivars dynamically), so custom
    # methods copied from the source keep working.
    def after_initialize; end

    def to_h
      @attrs
    end

    def [](key)
      @attrs[key.to_sym]
    end

    def ==(other)
      other.is_a?(self.class) && other.to_h == to_h
    end

    def inspect
      body = to_h.map { |key, value| "#{key}=#{value.inspect}" }.join(" ")
      "#<#{self.class.name} #{body}>"
    end

    def self.attributes
      {}
    end
  end
end
