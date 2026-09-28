# frozen_string_literal: true

# ruby-vips is a native C extension with no Spinel equivalent, so image
# conversion is unavailable in the native build. `new_from_buffer` answers an
# empty image (so the caller's pixel check is well typed) and `write_to_buffer`
# raises; the caller rescues, logs and keeps the original bytes.
module Vips
  class Error < StandardError; end

  class Image
    attr_accessor :width, :height

    def initialize
      @width  = 0
      @height = 0
    end

    def self.new_from_buffer(_data, _filename)
      new
    end

    def write_to_buffer(_suffix, _options = nil)
      raise Error, "libvips is not available in the native build"
    end
  end
end
