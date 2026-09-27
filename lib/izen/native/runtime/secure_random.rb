# frozen_string_literal: true

# `SecureRandom` stand-in. Reads /dev/urandom directly so it works under both
# CRuby and Spinel (File I/O is supported) without `require "securerandom"`
# (unsatisfiable under the Spinel require-gate).
module SecureRandom
  HEX = "0123456789abcdef"

  module_function

  def bytes(count)
    File.open("/dev/urandom", "rb") { |io| io.read(count) }
  end

  def hex(count)
    bytes(count).bytes.map { |byte| HEX[byte >> 4] + HEX[byte & 15] }.join
  end

  def urlsafe_base64(count)
    Base64Url.encode(bytes(count))
  end
end
