# frozen_string_literal: true

begin
  require "rack/files"
rescue LoadError
  require "rack/file"
end

module Izen
  module Storage
    # Serves a local service's directory at its URL prefix, mapping
    # /uploads/<key> to <path>/<key>. Rack::Static cannot express that (its
    # URL prefix is kept as part of the on-disk path), so this rewrites
    # PATH_INFO and delegates to Rack's file server. Missing files fall through
    # to the app instead of 404ing, so an application route still wins.
    class Static
      FILE_SERVER = defined?(Rack::Files) ? Rack::Files : Rack::File

      def initialize(app, url_prefix:, root:)
        @app   = app
        @url   = "/#{url_prefix.to_s.sub(%r{\A/+}, "").sub(%r{/+\z}, "")}"
        @root  = root
        @files = FILE_SERVER.new(root)
      end

      def call(env)
        return @app.call(env) unless %w[GET HEAD].include?(env["REQUEST_METHOD"])

        path = env["PATH_INFO"].to_s
        return @app.call(env) unless path.start_with?("#{@url}/")

        relative = path[@url.length, path.length].to_s.sub(%r{\A/+}, "")
        return @app.call(env) if relative.empty? || relative.include?("..")
        return @app.call(env) unless File.file?(File.join(@root, relative))

        env              = env.dup
        env["PATH_INFO"] = "/#{relative}"
        @files.call(env)
      rescue ArgumentError
        @app.call(env)
      end
    end
  end
end
