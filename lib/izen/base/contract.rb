# frozen_string_literal: true

require_relative "types"

module Izen
  module Base
    # A dependency-free data contract (a lean replacement for dry-validation).
    #
    # It declares the parameters it accepts, their types, and optional rules.
    # Calling the contract coerces the input and reports errors.
    #
    #   class Contract < Base::Contract
    #     params do
    #       required :name, String, min: 1, max: 120
    #       optional :age,  Integer, default: 0
    #     end
    #
    #     rule :password do
    #       error(:password, "confirmation does not match") if values[:password] != values[:password_confirmation]
    #     end
    #   end
    #
    #   result = Contract.new.call(params)
    #   result.success? # => true
    #   result.to_h     # => { name: "..." }
    #   result.errors   # => { name: ["wajib diisi"] }
    class Contract
      class Schema
        Field = Struct.new(:name, :type, :required, :default, :options, keyword_init: true)

        attr_reader :fields

        def initialize
          @fields = {}
        end

        def required(name, type = Object, **options)
          add(name, type, true, options)
        end

        def optional(name, type = Object, **options)
          add(name, type, false, options)
        end

        private

        def add(name, type, required, options)
          name          = name.to_sym
          @fields[name] = Field.new(
            name:     name,
            type:     type,
            required: required,
            default:  options[:default],
            options:  options
          )
        end
      end

      class Errors
        def initialize
          @messages = {}
        end

        def add(key, message)
          (@messages[key.to_sym] ||= []) << message
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
          @messages.transform_values(&:dup)
        end

        def full_messages
          @messages.flat_map do |key, messages|
            messages.map { |message| "#{key} #{message}" }
          end
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

      class << self
        # Declares the accepted parameters.
        def params(&block)
          @schema = Schema.new.tap { |schema| schema.instance_eval(&block) }
        end

        def schema
          return @schema if defined?(@schema) && @schema

          superclass.respond_to?(:schema) ? superclass.schema : Schema.new
        end

        def rules
          @rules ||= []
        end

        # Registers a custom validation. The block runs with the contract
        # instance as +self+, so +values+ and +error+ are available.
        def rule(*_keys, &block)
          rules << block
        end
      end

      attr_reader :values, :errors

      def call(params = {})
        @params = params
        @values = {}
        @errors = Errors.new

        validate_fields
        run_rules

        Result.new(@values, @errors)
      end

      private

      def validate_fields
        self.class.schema.fields.each do |name, field|
          raw = fetch(name)

          if blank?(raw)
            if field.required
              errors.add(name, "wajib diisi")
            else
              values[name] = field.default
            end
            next
          end

          begin
            value = Types.coerce(raw, field.type)
          rescue Types::CoercionError
            errors.add(name, "tidak valid")
            next
          end

          before       = errors[name].size
          validate_options(name, value, field.options)
          values[name] = value if errors[name].size == before
        end
      end

      def validate_options(name, value, options)
        if (pattern = options[:format]) && !(value.to_s =~ pattern)
          errors.add(name, "tidak valid")
        end

        if (allowed = options[:in]) && !allowed.include?(value)
          errors.add(name, "tidak termasuk dalam daftar")
        end

        if (min = options[:min]) && value.respond_to?(:length) && value.length < min
          errors.add(name, "terlalu pendek (minimal #{min} karakter)")
        end

        if (max = options[:max]) && value.respond_to?(:length) && value.length > max
          errors.add(name, "terlalu panjang (maksimal #{max} karakter)")
        end

        if (check = options[:validate]) && !check.call(value)
          errors.add(name, "tidak valid")
        end
      end

      def run_rules
        self.class.rules.each { |block| instance_exec(&block) }
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
end
