# frozen_string_literal: true

require "time"

module Base
  # Dependency-free type coercion, written in the subset Spinel can compile.
  #
  # This is the AOT build's replacement for `Izen::Base::Types`. `require "date"`
  # is not available under Spinel, so Date/DateTime values are kept as the
  # strings SQLite stores; Time is parsed from SQLite's fixed
  # "YYYY-MM-DD HH:MM:SS" UTC format without `Time.parse`.
  module Types
    class CoercionError < StandardError; end

    TYPE_ALIASES = {
      String     => :string,
      Integer    => :integer,
      Float      => :float,
      Numeric    => :numeric,
      TrueClass  => :boolean,
      FalseClass => :boolean,
      Symbol     => :symbol,
      Time       => :time,
      Array      => :array,
      Hash       => :hash
    }.freeze

    module_function

    def coerce(value, type)
      key = normalize_type(type)
      return value if key.nil?

      case key
      when :string   then value.is_a?(String) ? value : value.to_s
      when :integer  then to_integer(value)
      when :float    then to_float(value)
      when :numeric  then to_float(value)
      when :boolean  then boolean(value)
      when :symbol   then value.is_a?(Symbol) ? value : value.to_s.to_sym
      when :time     then parse_time(value)
      when :date     then value.to_s
      when :datetime then value.to_s
      when :array    then value.is_a?(Array) ? value : [ value ]
      when :hash     then value.is_a?(Hash) ? value : {}
      else
        raise CoercionError, "unsupported type #{type.inspect}"
      end
    end

    def normalize_type(type)
      case type
      when nil      then nil
      when Symbol   then type
      when Class    then TYPE_ALIASES[type] || type
      else type
      end
    end

    def valid?(value, type)
      coerce(value, type)
      true
    rescue CoercionError
      false
    end

    def to_integer(value)
      return value if value.is_a?(Integer)

      string = value.to_s
      raise CoercionError, "not an integer" unless string.match?(/\A-?\d+\z/)

      string.to_i
    end

    def to_float(value)
      return value if value.is_a?(Float)
      return value.to_f if value.is_a?(Integer)

      string = value.to_s
      raise CoercionError, "not a float" unless string.match?(/\A-?\d+(\.\d+)?\z/)

      string.to_f
    end

    def boolean(value)
      case value
      when true, false     then value
      when "true", "1", 1  then true
      when "false", "0", 0 then false
      else
        raise CoercionError, "cannot coerce #{value.inspect} to boolean"
      end
    end

    # SQLite stores timestamps as "YYYY-MM-DD HH:MM:SS" (UTC, from
    # datetime('now')). `Time.parse` does not exist under Spinel, so the fixed
    # format is parsed directly.
    def parse_time(value)
      return value if value.is_a?(Time)

      string = value.to_s
      match  = string.match(/\A(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2}):(\d{2})/)
      raise CoercionError, "invalid time" unless match

      Time.utc(
        match[1].to_i,
        match[2].to_i,
        match[3].to_i,
        match[4].to_i,
        match[5].to_i,
        match[6].to_i
      )
    end
  end
end
