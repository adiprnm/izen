# frozen_string_literal: true

require "date"
require "time"

module Izen
  module Base
    # Dependency-free type coercion shared by contracts and models.
    #
    # Types can be given either as a Symbol (:string, :integer, :boolean, :date,
    # :datetime, :time, :symbol, :array, :hash, :float, :numeric) or as the
    # corresponding Ruby class (String, Integer, Date, ...).
    module Types
      class CoercionError < StandardError; end

      # Maps a Ruby class type to its symbolic name.
      TYPE_ALIASES = {
        String     => :string,
        Integer    => :integer,
        Float      => :float,
        Numeric    => :numeric,
        TrueClass  => :boolean,
        FalseClass => :boolean,
        Symbol     => :symbol,
        Date       => :date,
        DateTime   => :datetime,
        Time       => :time,
        Array      => :array,
        Hash       => :hash
      }.freeze

      # Matches a trailing timezone designator (e.g. "Z" or "+07:00").
      TIMEZONE_SUFFIX = /(?:Z|[+-]\d{2}:?\d{2})\s*\z/i

      module_function

      # Coerces +value+ to +type+, raising CoercionError when impossible.
      def coerce(value, type)
        key = normalize_type(type)
        return value if key.nil? || key.equal?(Object)

        case key
        when :string   then value.is_a?(String) ? value : String(value)
        when :integer  then value.is_a?(Integer) ? value : Integer(value)
        when :float    then value.is_a?(Float) ? value : Float(value)
        when :numeric  then value.is_a?(Numeric) ? value : Float(value)
        when :boolean  then boolean(value)
        when :symbol   then value.is_a?(Symbol) ? value : value.to_sym
        when :datetime then value.is_a?(DateTime) ? value : DateTime.parse(value.to_s)
        when :date     then value.is_a?(Date) && !value.is_a?(DateTime) ? value : Date.parse(value.to_s)
        when :time     then value.is_a?(Time) ? value : parse_time(value)
        when :array    then value.is_a?(Array) ? value : Array(value)
        when :hash     then value.is_a?(Hash) ? value : value.to_h
        else
          raise CoercionError, "unsupported type #{type.inspect}"
        end
      rescue ArgumentError, TypeError => e
        raise CoercionError, e.message
      end

      # Normalizes Symbol and Class types into a Symbol (or returns them as is).
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

      def boolean(value)
        case value
        when true, false      then value
        when "true", "1", 1   then true
        when "false", "0", 0  then false
        else
          raise CoercionError, "cannot coerce #{value.inspect} to boolean"
        end
      end

      # SQLite stores timestamps in UTC without an offset. Time.parse would read
      # such a string in the server's local zone and shift the instant, so when
      # there is no timezone in the string we rebuild it explicitly as UTC.
      def parse_time(value)
        string = value.to_s
        time   = Time.parse(string)
        return time if string.match?(TIMEZONE_SUFFIX)

        Time.utc(time.year, time.month, time.day, time.hour, time.min, time.sec + time.subsec)
      end
    end
  end
end
