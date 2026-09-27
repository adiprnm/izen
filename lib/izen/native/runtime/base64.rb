# frozen_string_literal: true

# base64url without the `base64` gem (not available under Spinel).
module Base64Url
  ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

  module_function

  def encode(string)
    bytes  = string.to_s.bytes
    out    = "".dup
    i      = 0
    while i + 2 < bytes.length
      n = (bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2]
      out << ALPHABET[(n >> 18) & 63]
      out << ALPHABET[(n >> 12) & 63]
      out << ALPHABET[(n >> 6) & 63]
      out << ALPHABET[n & 63]
      i += 3
    end
    rest = bytes.length - i
    if rest == 1
      n = bytes[i] << 16
      out << ALPHABET[(n >> 18) & 63]
      out << ALPHABET[(n >> 12) & 63]
    elsif rest == 2
      n = (bytes[i] << 16) | (bytes[i + 1] << 8)
      out << ALPHABET[(n >> 18) & 63]
      out << ALPHABET[(n >> 12) & 63]
      out << ALPHABET[(n >> 6) & 63]
    end
    out
  end

  def decode(string)
    source = string.to_s
    out    = "".dup
    buffer = 0
    bits   = 0
    source.each_char do |char|
      index = ALPHABET.index(char)
      next unless index

      buffer = (buffer << 6) | index
      bits  += 6
      while bits >= 8
        bits -= 8
        out << ((buffer >> bits) & 0xFF).chr
      end
      buffer &= (1 << bits) - 1
    end
    out
  end
end
