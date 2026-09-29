# frozen_string_literal: true

# A Spinel-safe subset of Rack::Utils: only what this app calls.
#
# Implements exactly the CRuby/Rack 3 behaviour for `escape`, `escape_html`,
# `build_query`, `secure_compare` and `parse_nested_query` (so responses stay
# byte-identical to the Roda app).
module Rack
  module Utils
    module_function

    # Rack::Utils.escape_path = URI::RFC2396_Parser#escape: only characters
    # outside the URI-safe set are percent-encoded, so `:` and other reserved
    # sub-delims survive and a space becomes `%20` (not the form `+`).
    PATH_SAFE = "-_.!~*'();/?:@&=+$,[]"

    def escape_path(value)
      out = "".dup
      value.to_s.each_byte do |byte|
        char = byte.chr
        if (char >= "a" && char <= "z") ||
           (char >= "A" && char <= "Z") ||
           (char >= "0" && char <= "9") ||
           PATH_SAFE.include?(char)
          out << char
        else
          out << "%" << byte.to_s(16).upcase.rjust(2, "0")
        end
      end
      out
    end

    # --- escaping ---------------------------------------------------------

    def escape(value)
      out = "".dup
      value.to_s.each_byte do |byte|
        char = byte.chr
        if (char >= "a" && char <= "z") ||
           (char >= "A" && char <= "Z") ||
           (char >= "0" && char <= "9") ||
           char == "-" || char == "_" || char == "." || char == "~"
          out << char
        elsif char == " "
          out << "+"
        else
          out << "%" << byte.to_s(16).upcase.rjust(2, "0")
        end
      end
      out
    end

    def unescape(value)
      string = value.to_s
      out    = "".dup
      i      = 0
      while i < string.length
        char = string[i]
        if char == "+"
          out << " "
          i += 1
        elsif char == "%" && i + 2 < string.length
          out << string[i + 1, 2].to_i(16).chr
          i += 3
        else
          out << char
          i += 1
        end
      end
      out
    end

    # Percent-decoding for path segments: `+` stays a literal plus (only query
    # strings use it for a space), matching Rack::Utils.unescape_path.
    def unescape_path(value)
      string = value.to_s
      return string unless string.include?("%")

      out = "".dup
      i   = 0
      len = string.length
      while i < len
        char = string[i]
        if char == "%" && i + 2 < len
          out << string[i + 1, 2].to_i(16).chr
          i += 3
        else
          out << char
          i += 1
        end
      end
      out
    end

    def escape_html(value)
      string = value.to_s
      return string if string.empty?

      out = "".dup
      string.each_char do |char|
        case char
        when "&" then out << "&amp;"
        when "<" then out << "&lt;"
        when ">" then out << "&gt;"
        when '"' then out << "&quot;"
        when "'" then out << "&#39;"
        else out << char
        end
      end
      out
    end

    def build_query(params)
      parts = []
      params.each do |key, value|
        if value.is_a?(Array)
          value.each { |item| parts << "#{escape(key)}=#{escape(item)}" }
        elsif value.nil?
          parts << escape(key)
        else
          parts << "#{escape(key)}=#{escape(value)}"
        end
      end
      parts.join("&")
    end

    def secure_compare(a, b)
      left  = a.to_s
      right = b.to_s
      return false unless left.bytesize == right.bytesize

      result = 0
      i      = 0
      left.each_byte do |byte|
        result |= byte ^ right.getbyte(i)
        i      += 1
      end
      result == 0
    end

    # --- nested query parsing (ported from Rack::QueryParser) ------------

    def parse_nested_query(query)
      params = {}
      return params if query.nil? || query.empty?

      query.split("&").each do |pair|
        next if pair.empty?

        key, value = pair.split("=", 2)
        normalize(params, unescape(key), unescape(value.to_s), 0)
      end
      params
    end

    def normalize(params, name, value, depth)
      raise ArgumentError, "params too deep" if depth >= 32

      if depth.zero?
        start = name.index("[", 1)
        if start
          key   = name[0, start]
          after = name[start, name.length]
        else
          key   = name
          after = ""
        end
      elsif name.start_with?("[]")
        key   = "[]"
        after = name[2, name.length]
      elsif name.start_with?("[") && (closing = name.index("]", 1))
        key   = name[1, closing - 1]
        after = name[closing + 1, name.length]
      else
        key   = name
        after = ""
      end

      return params if key.empty?

      if after == ""
        if key == "[]" && depth != 0
          # handled by caller (array element)
        else
          params[key] = value
        end
      elsif after == "[]"
        params[key] ||= []
        params[key] << value
      elsif after.start_with?("[]") && after.length > 4 && after[2] == "[" && after.end_with?("]")
        child         = after[3, after.length - 4]
        params[key] ||= []
        last          = params[key].last
        if last.is_a?(Hash) && !hash_has_key?(last, child)
          normalize(last, child, value, depth + 1)
        else
          item = {}
          normalize(item, child, value, depth + 1)
          params[key] << item
        end
      else
        params[key] ||= {}
        normalize(params[key], after, value, depth + 1)
      end

      params
    end

    def hash_has_key?(hash, key)
      return false if key.include?("[]")

      parts   = key.split(/[\[\]]+/).reject(&:empty?)
      current = hash
      parts.each do |part|
        return false unless current.is_a?(Hash) && current.key?(part)

        current = current[part]
      end
      true
    end
  end
end
