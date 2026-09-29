# frozen_string_literal: true

require "tmpdir"
require_relative "secure_random"

# ruby-vips is a native C extension with no Spinel equivalent, so the image
# surface the app uses is backed by the `vips` command-line tool instead:
# `new_from_buffer` writes the bytes to a temp file and reads its dimensions
# with `vipsheader`, `write_to_buffer` runs `vips webpsave`. A missing tool
# raises (the caller rescues, logs and keeps the original bytes), so an upload
# never fails silently.
module Vips
  class Error < StandardError; end

  class Image
    attr_reader :width, :height, :path

    def initialize(path, width, height)
      @path   = path
      @width  = width
      @height = height
    end

    def self.new_from_buffer(data, filename = "")
      extension = File.extname(filename.to_s)
      path      = File.join(Dir.tmpdir, "vips_#{SecureRandom.hex(8)}#{extension}")

      begin
        File.open(path, "wb") { |file| file.write(data.to_s) }
        width  = header_value("width", path)
        height = header_value("height", path)
        raise Error, "unreadable image" if width <= 0 || height <= 0

        new(path, width, height)
      rescue StandardError
        File.delete(path) if File.file?(path)
        raise
      end
    end

    def self.header_value(field, path)
      `vipsheader -f #{field} #{escape(path)}`.strip.to_i
    end

    def self.escape(value)
      "'#{value.to_s.gsub("'", "'\\\\''")}'"
    end

    def write_to_buffer(suffix, options = nil)
      raise Error, "unsupported output format: #{suffix}" if suffix.to_s != ".webp"

      output  = "#{@path}#{suffix}"
      quality = options && (options[:Q] || options["Q"])

      command = +"vips webpsave #{self.class.escape(@path)} #{self.class.escape(output)}"
      command << " --Q #{quality.to_i}" if quality
      `#{command}`

      raise Error, "conversion produced no file" unless File.file?(output)

      data = File.binread(output)
      File.delete(output) if File.file?(output)
      File.delete(@path) if File.file?(@path)
      data
    end
  end
end
