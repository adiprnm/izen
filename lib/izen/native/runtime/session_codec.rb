# frozen_string_literal: true

require_relative "base64"
require_relative "secure_random"

# Signed-cookie codec. Mirrors `Base::Session` from the Roda app but uses the
# Spinel-safe crypto/random/base64 shims instead of OpenSSL/Digest/SecureRandom.
#
# Cookie value: `base64url(json) . base64url(hex(hmac_sha256(secret, json)))`.
module SessionCodec
  module_function

  def secret
    @secret ||= ENV["SESSION_SECRET"] || persisted_secret || SecureRandom.hex(64)
  end

  def persisted_secret
    # Relative to the app root (WORKDIR /app in the image), like the database
    # path — NOT `__dir__`, which the compiler bakes as the build-time path
    # and which does not exist in the runtime image.
    path = "storage/session_secret"
    if File.file?(path)
      value = File.read(path).strip
      return value unless value.empty?
    end

    value = SecureRandom.hex(64)
    File.write(path, value)
    value
  rescue SystemCallError
    nil
  end

  def encode(hash)
    payload = Base64Url.encode(generate_json(hash))
    "#{payload}.#{Base64Url.encode(hmac_hex(secret, payload))}"
  end

  def decode(value)
    payload, signature = value.to_s.split(".", 2)
    return {} unless payload && signature
    return {} unless Rack::Utils.secure_compare(hmac_hex(secret, payload), Base64Url.decode(signature))

    parsed = parse_json(Base64Url.decode(payload))
    parsed.is_a?(Hash) ? parsed : {}
  rescue StandardError
    {}
  end

  def hmac_hex(key, data)
    Crypto.hmac_sha256_hex(key, data)
  end

  # JSON is available under Spinel via `require "json"`; require it lazily so
  # this file also loads in plain CRuby.
  def generate_json(hash)
    require "json"
    JSON.generate(hash)
  end

  def parse_json(string)
    require "json"
    JSON.parse(string)
  end
end
