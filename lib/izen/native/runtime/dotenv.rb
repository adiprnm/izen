# frozen_string_literal: true

# Minimal .env loader for the generated application (no dependency). Reads
# KEY=VALUE pairs from `.env` without overwriting variables already set.
module Dotenv
  module_function

  def load(path = ".env")
    return unless File.file?(path)

    File.foreach(path) do |line|
      key, value = parse(line)
      next unless key

      ENV[key] = value unless ENV.key?(key)
    end
  end

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
