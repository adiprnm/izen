# frozen_string_literal: true

require "roda"
require "rack/method_override"
require "logger"
require "json"

require_relative "base/request_cache"
require_relative "base/session_plugin"
require_relative "health"
require_relative "storage"

module Izen
  # Base Roda application every Izen project subclasses.
  #
  # It wires the plugins a generated app always needs — template rendering,
  # flash messages and the signed-cookie session — and anchors their paths and
  # cookie key to the host application root (Izen.root). The subclass only has to
  # declare its routes:
  #
  #   class App < Izen::Application
  #     route do |r|
  #       r.get("health") { health }
  #       r.root { view("home") }
  #     end
  #   end
  #
  # Plugins are configured in .inherited rather than in this class body so the
  # app directory (Izen.root/app, which holds the views) is resolved *after*
  # the host app calls Izen.configure, not when the gem is first required.
  #
  # :all_verbs adds the r.put / r.delete / r.patch matchers (Roda only ships
  # r.get and r.post), and Rack::MethodOverride lets an HTML form — which can
  # only POST — reach them with a hidden `_method` field (or the
  # X-HTTP-Method-Override header).
  #
  # It also installs a set of production defaults an app can override:
  #
  # - security headers (nosniff / frame denial / referrer policy),
  # - friendly 404 and 500 pages that log the backtrace (override
  #   #render_not_found_page / #render_error_page, or add the optional
  #   `app/errors/not_found.erb` / `app/errors/error.erb` views),
  # - one access log line per request (#logger, override to customize),
  # - a per-request cache (`Izen::Base::RequestCache`),
  # - #health (JSON probe of the database and schema) and #rotate_session!.
  class Application < Roda
    # Headers stamped on every response, including error pages.
    SECURITY_HEADERS = {
      "x-content-type-options" => "nosniff",
      "x-frame-options"        => "DENY",
      "referrer-policy"        => "strict-origin-when-cross-origin"
    }.freeze

    class << self
      def inherited(subclass)
        super

        subclass.opts[:root] = Izen.root
        subclass.plugin :all_verbs
        subclass.plugin :render, views: "app"
        subclass.plugin :flash
        subclass.plugin :memory_session, key: "#{session_key(subclass)}_session"
        subclass.use Rack::MethodOverride
        mount_storage(subclass)
        install_defaults(subclass)
      end

      private

      # Wires the plugins and hooks behind the production defaults. An app can
      # override any of them by calling the plugin again with its own block.
      def install_defaults(subclass)
        subclass.plugin :default_headers, SECURITY_HEADERS
        subclass.plugin :hooks

        subclass.plugin :not_found do
          response.status = 404
          render_not_found_page
        end

        subclass.plugin :error_handler do |error|
          logger.error(
            "[error] #{request.request_method} #{request.path_info} -> " \
            "#{error.class}: #{error.message}\n#{Array(error.backtrace).first(15).join("\n")}"
          )
          response.status = 500
          render_error_page(error)
        end

        subclass.before do
          @request_started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          Izen::Base::RequestCache.begin!
        end

        subclass.after do |res|
          Izen::Base::RequestCache.end!
          log_access(res ? res[0] : 500)
        end
      end

      # Serves the local storage directory (`storage/uploads` by default) at the
      # configured URL (`/uploads`), so uploaded files are reachable without a
      # route. Skipped when the active service is not on-disk (a CDN or remote
      # backend), in which case #url points at that service directly.
      def mount_storage(subclass)
        url = Izen::Storage.public_url
        dir = Izen::Storage.public_dir
        return unless url && dir

        subclass.use Izen::Storage::Static, url_prefix: url, root: dir
      end

      # Cookie name for the session, derived from the subclass name so two apps
      # in the same browser do not share a session: App -> app_session.
      def session_key(subclass)
        name = subclass.name.to_s.split("::").last
        return "izen" if name.empty?

        name.gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase
      end
    end

    # Application logger. Outbound clients and the error handler use it; an app
    # can override it (e.g. to point at a file or a service).
    def logger
      @logger ||= Logger.new($stdout, level: ENV["APP_ENV"] == "test" ? Logger::ERROR : Logger::INFO)
    end

    # One access log line per request, quiet in tests. Called from the after
    # hook; override to change the format or skip some paths.
    def log_access(status)
      started  = @request_started_at
      duration = started ? ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(1) : nil
      suffix   = duration ? " #{duration}ms" : ""
      logger.info("[request] #{env["REQUEST_METHOD"]} #{env["PATH_INFO"]} #{status}#{suffix}")
    rescue StandardError
      nil
    end

    # Friendly 404 page. Renders the optional `errors/not_found` view; when the
    # app has none, returns nil so Roda keeps its default empty 404 body (which
    # also keeps source/native parity). Override to use a layout or another view.
    def render_not_found_page
      return unless view_exists?("errors/not_found")

      view("errors/not_found", layout: nil)
    rescue StandardError
      nil
    end

    # Friendly 500 page. Renders the optional `errors/error` view; when the app
    # has none, returns nil (empty body). The exception has already been logged.
    def render_error_page(_error)
      return unless view_exists?("errors/error")

      view("errors/error", layout: nil)
    rescue StandardError
      nil
    end

    # GET /health — JSON probe for load balancers and uptime monitors. Declare
    # `r.get("health") { health }` in the route block to expose it.
    def health
      result = Izen::Health.call

      response["content-type"] = "application/json; charset=utf-8"
      response.status          = result[:status] == "ok" ? 200 : 503
      JSON.generate(result)
    end

    # Drops the current session and starts a fresh one, keeping the listed keys
    # (e.g. the guest cart). Call after a successful login to defeat session
    # fixation; the CSRF token (if any) is regenerated as part of the new
    # session.
    def rotate_session!(options = {})
      values                                  = Array(options[:preserve]).to_h { |key| [ key, session[key] ] }.compact
      session.clear
      values.each { |key, value| session[key] = value }
      session
    end

    private

    # Whether a view template exists under the configured render views dir.
    def view_exists?(name)
      views = self.class.opts[:render][:views].to_s
      base  = views.start_with?("/") ? views : File.join(Izen.root, views)
      File.file?(File.join(base, "#{name}.erb"))
    end
  end
end
