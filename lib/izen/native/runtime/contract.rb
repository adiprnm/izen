# frozen_string_literal: true

require_relative "types"

module Base
  # Declarative data contract, lowered from `Izen::Base::Contract`.
  #
  # The generated subclass defines `self.fields` (instead of building a schema
  # with `instance_eval`) and, when the source declared rules, a `rules` method
  # holding the rule bodies verbatim.
  class Contract
    class Errors
      def initialize
        @messages = {}
      end

      def add(key, message)
        name              = key.to_sym
        @messages[name] ||= []
        @messages[name] << message
      end

      def [](key)
        @messages.fetch(key.to_sym, [])
      end

      def any?
        @messages.any?
      end

      def empty?
        @messages.empty?
      end

      def to_h
        out                                       = {}
        @messages.each { |key, messages| out[key] = messages.dup }
        out
      end

      def full_messages
        out = []
        @messages.each do |key, messages|
          messages.each { |message| out << "#{key} #{message}" }
        end
        out
      end
    end

    class Result
      attr_reader :values, :errors

      def initialize(values, errors)
        @values = values
        @errors = errors
      end

      def success?
        errors.empty?
      end

      def failure?
        !success?
      end

      def [](key)
        values[key.to_sym]
      end

      def to_h
        values
      end

      def error_messages
        errors.full_messages
      end
    end

    attr_reader :values, :errors

    def self.fields
      {}
    end

    def call(params = {})
      @params = params || {}
      @values = {}
      @errors = Errors.new

      validate_fields
      rules

      Result.new(@values, @errors)
    end

    def rules
    end

    private

    def validate_fields
      self.class.fields.each do |name, field|
        raw = fetch(name)

        if blank?(raw)
          if field[:required]
            errors.add(name, "wajib diisi")
          else
            values[name] = field[:default]
          end
          next
        end

        begin
          value = Types.coerce(raw, field[:type])
        rescue Types::CoercionError
          errors.add(name, "tidak valid")
          next
        end

        before       = errors[name].size
        validate_options(name, value, field)
        values[name] = value if errors[name].size == before
      end
    end

    def validate_options(name, value, field)
      if (pattern = field[:format]) && !pattern.match?(value.to_s)
        errors.add(name, "tidak valid")
      end

      if (allowed = field[:in]) && !allowed.include?(value)
        errors.add(name, "tidak termasuk dalam daftar")
      end

      length  = value.is_a?(String) || value.is_a?(Array) ? value.length : nil
      if (min = field[:min]) && length && length < min
        errors.add(name, "terlalu pendek (minimal #{min} karakter)")
      end

      if (max = field[:max]) && length && length > max
        errors.add(name, "terlalu panjang (maksimal #{max} karakter)")
      end

      if (check = field[:validate]) && !check.call(value)
        errors.add(name, "tidak valid")
      end
    end

    def fetch(name)
      return @params[name] if @params.key?(name)
      return @params[name.to_s] if @params.key?(name.to_s)

      nil
    end

    def blank?(value)
      value.nil? || (value.respond_to?(:empty?) && value.empty?)
    end

    def error(key, message)
      errors.add(key, message)
    end
  end
end
