# frozen_string_literal: true

require "base64"
require "digest"
require "fileutils"
require "json"
require "rack/utils"
require "securerandom"

module Izen
  module Base
    # Signed-cookie codec used by the :memory_session Roda plugin.
    #
    # Roda's own :sessions plugin encrypts its cookie with AES through OpenSSL,
    # which pulls ~7 MB of OpenSSL into every process. This app only stores an
    # opaque session id and transient flash strings, so a signed (not encrypted)
    # cookie is enough: the client cannot tamper with it, and nothing secret is
    # revealed by reading it.
    #
    # The value is `base64url(json) . base64url(hmac_sha256(json))`.
    module Session
      BLOCK_SIZE = 64

      module_function

      # The signing key, memoized so a missing env var yields one stable key
      # instead of a new key on every call.
      #
      # Resolution order: SESSION_SECRET env var, then a key persisted on the
      # storage volume (so sessions survive deploys/restarts without config),
      # then a random per-process key as a last resort.
      def secret
        @secret ||= ENV["SESSION_SECRET"] || persisted_secret || SecureRandom.hex(64)
      end

      # Reads (or creates) storage/session_secret. Lives next to the SQLite file
      # so it is kept by the same Kamal volume across container versions.
      def persisted_secret
        path = File.join(Izen.root, "storage", "session_secret")
        FileUtils.mkdir_p(File.dirname(path))
        if File.file?(path)
          value = File.read(path).strip
          return value unless value.empty?
        end

        value = SecureRandom.hex(64)
        File.write(path, value)
        File.chmod(0o600, path)
        value
      rescue SystemCallError
        nil
      end

      def encode(hash)
        payload = b64(JSON.generate(hash))
        "#{payload}.#{b64(hmac(payload))}"
      end

      # Returns the decoded hash, or an empty hash when the value is missing,
      # malformed, or its signature does not verify.
      def decode(value)
        payload, signature = value.to_s.split(".", 2)
        return {} unless payload && signature
        return {} unless Rack::Utils.secure_compare(hmac(payload), unb64(signature))

        parsed = JSON.parse(unb64(payload))
        parsed.is_a?(Hash) ? parsed : {}
      rescue JSON::ParserError, ArgumentError
        {}
      end

      # HMAC-SHA256 built on Digest so OpenSSL is never loaded:
      # H((key' ^ opad) || H((key' ^ ipad) || data)), with key' the key
      # hashed-if-long and padded to the hash block size.
      def hmac(data)
        key  = secret
        key  = Digest::SHA256.digest(key) if key.bytesize > BLOCK_SIZE
        key  = key.ljust(BLOCK_SIZE, "\0")
        ipad = key.bytes.map { |byte| byte ^ 0x36 }.pack("C*")
        opad = key.bytes.map { |byte| byte ^ 0x5c }.pack("C*")
        Digest::SHA256.digest(opad + Digest::SHA256.digest(ipad + data))
      end

      def b64(string)
        Base64.urlsafe_encode64(string, padding: false)
      end

      def unb64(string)
        Base64.urlsafe_decode64(string)
      end
    end
  end
end
