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

# Spinel has no Date. The app builds Date objects for period ranges, formatting
# and arithmetic over the ISO "YYYY-MM-DD" strings SQLite stores, so this
# implements the surface it uses (today/parse/new, +/-/>>, comparisons and
# to_s). Gregorian date <-> Julian day conversion is the standard algorithm.
class Date
  include Comparable

  class Error < ArgumentError; end

  MONTH_DAYS = [ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 ].freeze

  attr_reader :year, :month, :day, :jd

  def self.today
    now = Time.now
    new(now.year, now.month, now.day)
  end

  def self.parse(value)
    match = value.to_s.match(/\A(\d{4})-(\d{1,2})-(\d{1,2})/)
    raise Error, "invalid date: #{value}" unless match

    new(match[1].to_i, match[2].to_i, match[3].to_i)
  end

  def self.from_jd(jd)
    a     = jd + 32044
    b     = (4 * a + 3) / 146097
    c     = a - (146097 * b) / 4
    d     = (4 * c + 3) / 1461
    e     = c - (1461 * d) / 4
    m     = (5 * e + 2) / 153
    day   = e - (153 * m + 2) / 5 + 1
    month = m + 3 - 12 * (m / 10)
    year  = 100 * b + d - 4800 + m / 10
    new(year, month, day)
  end

  def self.leap?(year)
    (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
  end

  def self.days_in_month(year, month)
    return 29 if month == 2 && leap?(year)

    MONTH_DAYS[month - 1]
  end

  def self.jd(year, month, day)
    a = (14 - month) / 12
    y = year + 4800 - a
    m = month + 12 * a - 3
    day + (153 * m + 2) / 5 + 365 * y + y / 4 - y / 100 + y / 400 - 32045
  end

  def initialize(year, month, day)
    @year  = year
    @month = month
    @day   = day
    @jd    = Date.jd(year, month, day)
  end

  def wday
    (@jd + 1) % 7
  end

  def +(other)
    Date.from_jd(@jd + other.to_i)
  end

  def -(other)
    return @jd - other.jd if other.is_a?(Date)

    Date.from_jd(@jd - other.to_i)
  end

  def >>(months)
    total = @year * 12 + (@month - 1) + months.to_i
    year  = total / 12
    month = total % 12 + 1
    day   = [ @day, Date.days_in_month(year, month) ].min
    Date.new(year, month, day)
  end

  def <<(months)
    total = @year * 12 + (@month - 1) - months.to_i
    year  = total / 12
    month = total % 12 + 1
    day   = [ @day, Date.days_in_month(year, month) ].min
    Date.new(year, month, day)
  end

  def succ
    self + 1
  end

  def <=>(other)
    @jd <=> other.jd
  end

  def ==(other)
    other.is_a?(Date) && @jd == other.jd
  end

  def eql?(other)
    self == other
  end

  def hash
    @jd
  end

  def to_s
    "#{pad(@year, 4)}-#{pad(@month, 2)}-#{pad(@day, 2)}"
  end

  def inspect
    to_s
  end

  private

  def pad(value, width)
    string = value.to_s
    string = "0#{string}" while string.length < width
    string
  end
end
