# frozen_string_literal: true

require "securerandom"

module Izen
  module Storage
    # Storage keys are relative, forward-slash paths with no traversal: the
    # only place a request-supplied filename is turned into a path.
    module Key
      EXTENSION = /\A\.[a-z0-9]{1,8}\z/

      module_function

      # A date-sharded, random key that preserves a safe extension from the
      # original filename: 2026/10/9f…c1.png.
      def generate(filename)
        extension = File.extname(filename.to_s).downcase
        extension = "" unless extension.match?(EXTENSION)
        "#{Time.now.utc.strftime("%Y/%m")}/#{SecureRandom.hex(16)}#{extension}"
      end

      def normalize(key)
        key   = key.to_s.tr("\\", "/").sub(%r{\A/+}, "")
        parts = key.split("/")
        if key.empty? || parts.any? { |part| part.empty? || part == "." || part == ".." }
          raise Error, "invalid storage key #{key.inspect}"
        end

        key
      end
    end
  end
end
