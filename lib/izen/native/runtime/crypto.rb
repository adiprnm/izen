# frozen_string_literal: true

require "digest"

# HMAC-SHA256 over Spinel's bundled `digest` package (native SHA-256 with no
# carried C). CRuby's OpenSSL is deliberately not used: the `openssl` package
# declares `native_struct "X509::Store"`, whose leaf key collides with any app
# class named `Store`. The output is the standard RFC 2104 HMAC.
module Crypto
  BLOCK_SIZE = 64
  HEX        = "0123456789abcdef"

  module_function

  # Raw RFC 2104 HMAC-SHA256 (binary), used for the SigV4 signing-key chain and
  # PBKDF2. The hex spelling below is the commonly called one.
  def hmac_sha256(key, data)
    key    = key.to_s
    padded = key.bytes
    padded = Digest::SHA256.digest(key).bytes if padded.length > BLOCK_SIZE
    padded = padded + Array.new(BLOCK_SIZE - padded.length, 0)

    inner = Digest::SHA256.digest(pack_xor(padded, 0x36) + data.to_s)
    Digest::SHA256.digest(pack_xor(padded, 0x5c) + inner)
  end

  def hmac_sha256_hex(key, data)
    to_hex(hmac_sha256(key, data))
  end

  def sha256(data)
    Digest::SHA256.digest(data.to_s)
  end

  def sha256_hex(data)
    Digest::SHA256.hexdigest(data.to_s)
  end

  # PBKDF2-HMAC-SHA256 (RFC 8018). The signing key is constant across the
  # iterations, so the HMAC ipad/opad are built once. Enough for the AES key
  # derivation Izen::Encryptor uses.
  def pbkdf2_hmac_sha256(password, salt, iterations, length)
    bytes  = password.to_s.bytes
    bytes  = Digest::SHA256.digest(password.to_s).bytes if bytes.length > BLOCK_SIZE
    bytes  = bytes + Array.new(BLOCK_SIZE - bytes.length, 0)
    ipad   = pack_xor(bytes, 0x36)
    opad   = pack_xor(bytes, 0x5c)
    blocks = (length + 31) / 32
    out    = "".dup

    (1..blocks).each do |index|
      u = Digest::SHA256.digest(opad + Digest::SHA256.digest(ipad + salt.to_s + int32_be(index)))
      t = u
      i = 1
      while i < iterations
        u  = Digest::SHA256.digest(opad + Digest::SHA256.digest(ipad + u))
        t  = xor_bytes(t, u)
        i += 1
      end
      out << t
    end

    out.byteslice(0, length)
  end

  def pack_xor(bytes, mask)
    out = "".dup
    bytes.each { |byte| out << (byte ^ mask).chr }
    out
  end

  def xor_bytes(left, right)
    out  = "".dup
    size = left.bytesize
    i    = 0
    while i < size
      out << (left.getbyte(i) ^ right.getbyte(i)).chr
      i += 1
    end
    out
  end

  def int32_be(value)
    (value >> 24).chr + ((value >> 16) & 0xFF).chr + ((value >> 8) & 0xFF).chr + (value & 0xFF).chr
  end

  def to_hex(bytes)
    out = "".dup
    bytes.each_byte { |byte| out << HEX[byte >> 4] << HEX[byte & 15] }
    out
  end
end
