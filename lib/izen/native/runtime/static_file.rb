# frozen_string_literal: true

require_relative "storage"

# Serves files from `public/` (Roda's `plugin :public` + `r.public`) and the
# local storage directory under /uploads (`Storage.public_dir`), matching the
# CRuby app's Rack::Static mount.
module StaticFile
  TYPES = {
    ".css"   => "text/css; charset=utf-8",
    ".js"    => "application/javascript; charset=utf-8",
    ".mjs"   => "application/javascript; charset=utf-8",
    ".json"  => "application/json",
    ".txt"   => "text/plain; charset=utf-8",
    ".svg"   => "image/svg+xml",
    ".png"   => "image/png",
    ".jpg"   => "image/jpeg",
    ".jpeg"  => "image/jpeg",
    ".gif"   => "image/gif",
    ".webp"  => "image/webp",
    ".ico"   => "image/x-icon",
    ".woff"  => "font/woff",
    ".woff2" => "font/woff2",
    ".map"   => "application/json"
  }.freeze

  module_function

  # Returns a Response for an existing file under `public/` or the local
  # storage directory, or nil to fall through to the application.
  def serve(request)
    return nil unless request.request_method == "GET"
    return nil unless request.path_info.start_with?("/") && !request.path_info.include?("..")

    path = request.path_info
    return nil if path == "/"

    file = resolve(path)
    return nil unless file && File.file?(file)

    response                  = Response.new
    response.status           = 200
    response["Content-Type"]  = content_type(file)
    response["Cache-Control"] = "public, max-age=3600"
    response.body             = File.read(file)
    response
  end

  # Maps /uploads/<key> onto Storage.public_dir and everything else onto
  # public/<path>. Returns nil for a path the app should handle.
  def resolve(path)
    upload = Storage.public_url
    if path == upload || path.start_with?("#{upload}/")
      rest = path[upload.length, path.length].to_s.sub(/\A\/+/, "")
      return nil if rest.empty? || rest.include?("..")

      "#{Storage.public_dir}/#{rest}"
    else
      "public#{path}"
    end
  end

  def content_type(file)
    extension = ""
    index     = file.rindex(".")
    extension = file[index, file.length] if index
    TYPES[extension] || "application/octet-stream"
  end
end
