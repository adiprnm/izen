# frozen_string_literal: true

# HMAC-SHA256. On CRuby this uses OpenSSL; under Spinel the openssl package
# (or a small FFI binding to sp_crypto_hmac_sha256_hex) provides it. Only the
# hex form is needed, which keeps the surface identical on both.
module Crypto
  module_function

  def hmac_sha256_hex(key, data)
    require "openssl" unless defined?(OpenSSL::HMAC)
    OpenSSL::HMAC.hexdigest("SHA256", key.to_s, data.to_s)
  end
end
