# frozen_string_literal: true

require "digest"

# HMAC-SHA256 over Spinel's bundled `digest` package (native SHA-256 with no
# carried C). CRuby's OpenSSL is deliberately not used: the `openssl` package
# declares `native_struct "X509::Store"`, whose leaf key collides with any app
# class named `Store`. The output is the standard RFC 2104 HMAC.
module Crypto
  BLOCK_SIZE = 64

  module_function

  def hmac_sha256_hex(key, data)
    key    = key.to_s
    padded = key.bytes
    padded = Digest::SHA256.digest(key).bytes if padded.length > BLOCK_SIZE
    padded = padded + Array.new(BLOCK_SIZE - padded.length, 0)

    inner = Digest::SHA256.digest(pack_xor(padded, 0x36) + data.to_s)
    Digest::SHA256.hexdigest(pack_xor(padded, 0x5c) + inner)
  end

  def pack_xor(bytes, mask)
    out = "".dup
    bytes.each { |byte| out << (byte ^ mask).chr }
    out
  end
end
