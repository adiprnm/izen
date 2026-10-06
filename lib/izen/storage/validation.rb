# frozen_string_literal: true

module Izen
  module Storage
    # Validation policy for image uploads.
    #
    # Izen::Storage already generates a random, safe key (the client filename
    # only supplies the extension), so this guards the remaining risks: a
    # non-image disguised with an image extension, an oversized file, and a
    # disallowed type. Validation reads the magic bytes from the tempfile and
    # rewinds it, so the caller can hand the same upload to Storage afterwards.
    #
    #   error = Izen::Storage.image_error(params["avatar"])
    #   return flash("alert", error) if error
    #   key = Izen::Storage.store(params["avatar"])
    module Validation
      IMAGE_TYPES      = %w[image/jpeg image/png image/webp].freeze
      IMAGE_EXTENSIONS = %w[jpg jpeg png webp].freeze
      MAX_IMAGE_BYTES  = 5 * 1024 * 1024

      class << self
        # Returns nil when +upload+ is an acceptable image, otherwise a
        # human-readable reason.
        def image_error(upload)
          return "Berkas tidak dikenali." unless upload?(upload)

          extension = File.extname(filename(upload)).delete_prefix(".").downcase
          return "Format gambar harus JPG, PNG, atau WEBP." unless IMAGE_EXTENSIONS.include?(extension)

          type = content_type(upload).to_s.downcase
          if !type.empty? && type != "application/octet-stream" && !IMAGE_TYPES.include?(type)
            return "Tipe berkas tidak didukung."
          end

          size = byte_size(upload)
          return "Ukuran gambar maksimal 5 MB." if size && size > MAX_IMAGE_BYTES

          return "Isi berkas bukan gambar yang valid." unless image_signature?(upload)

          nil
        end

        def image?(upload)
          image_error(upload).nil?
        end

        def upload?(upload)
          upload.is_a?(Hash) || upload.respond_to?(:tempfile) || upload.respond_to?(:original_filename)
        end

        private

        def filename(upload)
          if upload.is_a?(Hash)
            upload[:filename] || upload["filename"] || upload[:original_filename] || upload["original_filename"]
          elsif upload.respond_to?(:original_filename)
            upload.original_filename
          end.to_s
        end

        def content_type(upload)
          if upload.is_a?(Hash)
            upload[:type] || upload["type"] || upload[:content_type] || upload["content_type"]
          elsif upload.respond_to?(:content_type)
            upload.content_type
          end.to_s
        end

        def byte_size(upload)
          io = tempfile(upload)
          io.size if io.respond_to?(:size)
        end

        # JPEG starts with FF D8 FF; PNG with 89 50 4E 47; WEBP is "RIFF" at 0
        # and "WEBP" at 8.
        def image_signature?(upload)
          io = tempfile(upload)
          return false unless io

          io.rewind if io.respond_to?(:rewind)
          head = io.read(16).to_s.b
          io.rewind if io.respond_to?(:rewind)
          return false if head.empty?

          return true if head.start_with?("\xFF\xD8\xFF".b) || head.start_with?("\x89PNG".b)
          return head[0, 4] == "RIFF" && head[8, 4] == "WEBP" if head.bytesize >= 12

          false
        rescue IOError, SystemCallError
          false
        end

        def tempfile(upload)
          if upload.is_a?(Hash)
            upload[:tempfile] || upload["tempfile"]
          elsif upload.respond_to?(:tempfile)
            upload.tempfile
          end
        end
      end
    end
  end
end
