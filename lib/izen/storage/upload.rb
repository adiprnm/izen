# frozen_string_literal: true

module Izen
  module Storage
    # Reads the many shapes an upload arrives in without the caller caring which
    # one it has: a Rack multipart hash, an uploaded-file object, a File/IO or a
    # path on disk.
    module Upload
      module_function

      def filename(upload)
        case upload
        when Hash
          clean(
            upload[:filename] || upload["filename"] ||
            upload[:original_filename] || upload["original_filename"]
          )
        when String
          clean(upload)
        else
          name   = upload.respond_to?(:original_filename) ? upload.original_filename : nil
          name ||= upload.respond_to?(:path) ? upload.path : nil
          clean(name)
        end
      end

      # Copies the upload's bytes to +destination+. The IO is rewound first; an
      # IO the caller handed us is left open (it owns it), a file opened from a
      # path is closed.
      def copy(upload, destination)
        io, close = io_for(upload)
        io.rewind if io.respond_to?(:rewind)
        File.open(destination, "wb") { |file| IO.copy_stream(io, file) }
      ensure
        io.close if close && io
      end

      def io_for(upload)
        if upload.is_a?(Hash)
          io = upload[:tempfile] || upload["tempfile"]
          raise Error, "upload hash is missing :tempfile" unless io

          [ io, false ]
        elsif upload.respond_to?(:tempfile)
          [ upload.tempfile, false ]
        elsif upload.respond_to?(:read)
          [ upload, false ]
        elsif upload.is_a?(String)
          raise Error, "no such file: #{upload}" unless File.file?(upload)

          [ File.open(upload, "rb"), true ]
        else
          raise Error, "cannot read an upload from #{upload.class}"
        end
      end

      # The basename only: a client-supplied name must never pick the path.
      def clean(name)
        name.to_s.tr("\\", "/").split("/").last.to_s
      end

      # The upload's declared MIME type, or a safe default for a backend that
      # stores it (S3).
      def content_type(upload)
        type =
          if upload.is_a?(Hash)
            upload[:type] || upload["type"] || upload[:content_type] || upload["content_type"]
          elsif upload.respond_to?(:content_type)
            upload.content_type
          end
        type.to_s.empty? ? "application/octet-stream" : type.to_s
      end
    end
  end
end
