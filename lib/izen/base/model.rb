# frozen_string_literal: true

require_relative "types"

module Izen
  module Base
    # A tiny attribute-based value object (a lean replacement for dry-struct).
    #
    # The model is only in charge of *describing and holding* the domain
    # attributes. It does not know about persistence or validation.
    #
    #   class Model < Base::Model
    #     attribute  :id,         Integer, required: false
    #     attribute  :name,       String
    #     attribute  :created_at, Time,    required: false
    #   end
    class Model
      class << self
        # Declares an attribute. +type+ informs the programmer (and the caster)
        # what the attribute holds.
        def attribute(name, type = Object, required: true, default: nil)
          name             = name.to_sym
          attributes[name] = { type: type, required: required, default: default }
          attr_accessor name
        end

        def attributes
          @attributes ||= {}
        end

        # All attributes, including those declared on parent classes.
        def all_attributes
          parent = superclass.respond_to?(:all_attributes) ? superclass.all_attributes : {}
          parent.merge(attributes)
        end
      end

      # Accepts either a Hash (with symbol or string keys) or keyword arguments,
      # e.g. `Model.new(row)`, `Model.new(name: "a")` or `Model.new(row, strict: false)`.
      #
      # With +strict: false+ values are neither coerced nor required, which is
      # useful to re-render a form with the raw, possibly invalid, input.
      def initialize(values = nil, strict: true, **attributes)
        @strict = strict
        values  = values.respond_to?(:to_h) ? values.to_h : values
        values  = normalize((values || {}).merge(attributes))

        self.class.all_attributes.each do |name, spec|
          value   = resolve(name, values, spec)
          coerced = value.nil? || !strict ? value : Types.coerce(value, spec[:type])
          instance_variable_set(:"@#{name}", coerced)
        end
      end

      def to_h
        self.class.all_attributes.keys.each_with_object({}) do |name, memo|
          memo[name] = public_send(name)
        end
      end

      def ==(other)
        other.is_a?(self.class) && other.to_h == to_h
      end
      alias eql? ==

      def hash
        [ self.class, to_h ].hash
      end

      def inspect
        body = to_h.map { |key, value| "#{key}=#{value.inspect}" }.join(" ")
        "#<#{self.class.name} #{body}>"
      end

      private

      def resolve(name, values, spec)
        return values[name] if values.key?(name)
        return spec[:default] unless spec[:default].nil?

        if spec[:required] && @strict
          raise ArgumentError, "missing required attribute :#{name} for #{self.class}"
        end

        nil
      end

      def normalize(values)
        case values
        when Hash
          values.each_with_object({}) { |(key, value), memo| memo[key.to_sym] = value }
        when Model
          values.to_h
        else
          raise ArgumentError, "expected a Hash, got #{values.class}" unless values.respond_to?(:to_h)

          normalize(values.to_h)
        end
      end
    end
  end
end
