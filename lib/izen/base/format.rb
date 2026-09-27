# frozen_string_literal: true

module Izen
  module Base
    # Small display formatters shared by controllers and views: numbers,
    # currency, timestamps and relative-age labels.
    module Format
      module_function

      # Zone used when rendering timestamps. Override it at boot to match your
      # audience, e.g. `Base::Format::DISPLAY_OFFSET = "+07:00"`. UTC is the safe
      # default.
      DISPLAY_OFFSET = "+00:00"

      # Timestamp layout used by #datetime.
      DATETIME_FORMAT = "%d %b %Y %H:%M"

      # Currency symbol prefixed by #money.
      CURRENCY_SYMBOL = "Rp"

      # Thousands separator used by #number and #money.
      THOUSANDS_SEPARATOR = "."

      # Groups thousands in an integer, e.g. 65000 -> "65.000".
      def number(value)
        sign   = value.negative? ? "-" : ""
        digits = value.abs.to_i.to_s
        sign + digits.reverse.scan(/\d{1,3}/).join(THOUSANDS_SEPARATOR).reverse
      end

      # Formats an integer amount with the currency symbol, e.g. 65000 -> "Rp65.000".
      def money(amount)
        sign = amount.negative? ? "-" : ""
        "#{sign}#{CURRENCY_SYMBOL}#{number(amount.abs)}"
      end

      # Renders a timestamp in DISPLAY_OFFSET, e.g. "25 Sep 2026 01:21".
      # nil renders as an empty string.
      def datetime(time)
        return "" unless time

        time.getlocal(DISPLAY_OFFSET).strftime(DATETIME_FORMAT)
      end

      # Compact relative label (s = seconds, m = minutes, h = hours, d = days).
      # nil renders as an empty string. +now+ lets callers (and tests) pin the
      # reference instant.
      def age(then_time, now = Time.now)
        return "" unless then_time

        seconds = [ (now - then_time).to_i, 0 ].max
        return "#{seconds}s" if seconds < 60
        return "#{seconds / 60}m" if seconds < 3600
        return "#{seconds / 3600}h" if seconds < 86_400

        "#{seconds / 86_400}d"
      end
    end
  end
end
