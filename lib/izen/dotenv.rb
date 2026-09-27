# frozen_string_literal: true

# Minimal .env loader (no dependency).
#
# Reads KEY=VALUE pairs from a .env file into ENV, without overwriting
# variables that are already set. Intended for local development only.
module Izen
  module Dotenv
    module_function

    def load(path = File.join(Izen.root, ".env"))
      return unless File.file?(path)

      File.foreach(path) do |line|
        key, value = parse(line)
        next unless key

        ENV[key] = value unless ENV.key?(key)
      end
    end

    # Returns [key, value] for a `KEY=VALUE` line, or nil for blanks/comments.
    def parse(line)
      line = line.strip
      return nil if line.empty? || line.start_with?("#")

      key, value = line.split("=", 2)
      return nil if key.nil? || value.nil?

      [ key.strip, unquote(value.strip) ]
    end

    def unquote(value)
      return value unless value.length >= 2

      if (value.start_with?('"') && value.end_with?('"')) ||
         (value.start_with?("'") && value.end_with?("'"))
        value[1...-1]
      else
        value
      end
    end
  end
end
