# frozen_string_literal: true

require_relative "secure_random"

# Minimal bcrypt without the `bcrypt` gem. `String#crypt` (libxcrypt) supports
# the `$2b$` scheme on CRuby and under Spinel, so only the salt/compare glue is
# needed. Mirrors the slice of the bcrypt gem that apps use:
#
#   BCrypt::Password.create(password).to_s
#   BCrypt::Password.new(hash) == provided_password
#   BCrypt::Errors::InvalidHash
module BCrypt
  module Errors
    class InvalidHash < StandardError; end
  end

  module Engine
    DEFAULT_COST = 12
    MIN_COST     = 4
    MAX_COST     = 31
  end

  class Password
    # A bcrypt hash is "$2b$" + 2-digit cost + "$" + 53 salt/hash characters.
    HASH_PATTERN = /\A\$2[abxy]?\$\d{2}\$[.\/A-Za-z0-9]{53}\z/
    ALPHABET     = "./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"

    class << self
      def create(password, cost = Engine::DEFAULT_COST)
        new(hash_for(password, cost))
      end

      # Generates "$2b$<cost>$<22-char salt>" and lets libxcrypt do the work.
      def hash_for(password, cost)
        cost_text = cost < 10 ? "0#{cost}" : cost.to_s
        salt      = salt_text(22)
        password.to_s.crypt("$2b$#{cost_text}$#{salt}")
      end

      def salt_text(length)
        text = "".dup
        SecureRandom.bytes(length).bytes.each do |byte|
          text << ALPHABET[byte % 64]
        end
        text
      end
    end

    def initialize(hash)
      raise Errors::InvalidHash, "invalid bcrypt hash" unless HASH_PATTERN.match?(hash.to_s)

      @hash = hash.to_s
    end

    def ==(other)
      @hash == other.to_s.crypt(@hash)
    end

    # Alias used by the app (`User#authenticate`).
    def is_password?(password)
      self == password
    end

    def to_s
      @hash
    end

    def to_str
      @hash
    end
  end
end
