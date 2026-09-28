# frozen_string_literal: true

# ruby-vips is a native C extension with no Spinel equivalent, so image
# conversion is unavailable in the native build. The methods raise and callers
# rescue, log and keep the original bytes.
module Vips
  class Error < StandardError; end

  class Image
    def self.new_from_buffer(_data, _filename)
      raise Error, "libvips is not available in the native build"
    end
  end
end
