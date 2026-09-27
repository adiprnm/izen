require "openssl"
require "base64"
require "json"
require "securerandom"
require "digest"

# AES-256-GCM encrypt/decrypt.
# Key derived via PBKDF2-HMAC-SHA256 from ENV["APP_ENCRYPTION_KEY"].
module Izen
  module Encryptor
    PBKDF2_ITERATIONS = 20_000

    def self.encrypt(plaintext)
      cipher     = OpenSSL::Cipher.new("aes-256-gcm")
      cipher.encrypt
      salt       = SecureRandom.random_bytes(16)
      cipher.key = derive_key(salt)
      iv         = cipher.random_iv
      ciphertext = cipher.update(plaintext) + cipher.final
      tag        = cipher.auth_tag

      JSON.generate(
        {
          ct:   Base64.strict_encode64(ciphertext),
          iv:   Base64.strict_encode64(iv),
          tag:  Base64.strict_encode64(tag),
          salt: Base64.strict_encode64(salt)
        }
      )
    end

    def self.decrypt(payload)
      data              = JSON.parse(payload)
      salt              = data["salt"] ? Base64.decode64(data["salt"]) : nil
      if salt.nil?
        # Legacy payloads encrypted before salting used SHA256(master) directly.
        # Still decrypts for backward compat, but the KDF is weaker — warn so the
        # secret gets re-saved (Encryptor.encrypt always salts) and upgraded.
        warn "[Encryptor] legacy no-salt payload — re-save this secret to upgrade key derivation"
      end
      decipher          = OpenSSL::Cipher.new("aes-256-gcm")
      decipher.decrypt
      decipher.key      = derive_key(salt)
      decipher.iv       = Base64.decode64(data["iv"])
      decipher.auth_tag = Base64.decode64(data["tag"])
      decipher.update(Base64.decode64(data["ct"])) + decipher.final
    end

    def self.derive_key(salt)
      master = ENV["APP_ENCRYPTION_KEY"] or raise "Set APP_ENCRYPTION_KEY in environment"
      if salt
        OpenSSL::KDF.pbkdf2_hmac(master, salt: salt, iterations: PBKDF2_ITERATIONS, length: 32, hash: "sha256")
      else
        Digest::SHA256.digest(master)
      end
    end

    private_class_method :derive_key
  end
end
