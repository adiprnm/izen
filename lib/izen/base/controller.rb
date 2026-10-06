# frozen_string_literal: true

module Izen
  module Base
    # Base controller. Stores the Roda application instance so subclasses can
    # render views and set flash messages without receiving it on every call.
    #
    # Controllers orchestrate the flow:
    #
    #   read:   controller -> repository -> view
    #   write:  controller -> contract -> model -> repository -> view
    #
    # The host app's own helpers (settings lookups, cart, admin auth, ...) are
    # reached through #method_missing, which forwards to the Roda app instance,
    # so this base class stays free of app-specific knowledge.
    class Controller
      attr_reader :app

      def initialize(app)
        @app = app
      end

      private

      # Renders +template+ inside the layout. Locals are also exposed as
      # instance variables so views can use @product etc.
      def render(template, locals = {}, layout: nil, **kwargs)
        locals           = locals.merge(kwargs)
        locals.each { |key, value| app.instance_variable_set(:"@#{key}", value) }
        options          = { locals: locals }
        options[:layout] = layout unless layout.nil?
        app.view(template, **options)
      end

      # --- request context -------------------------------------------------

      def session = app.session
      def params = app.params
      def request = app.request
      def response = app.response
      def h(text) = app.h(text)
      def logger = app.logger
      def headers = app.response.headers
      def halt(*args, &block) = request.halt(*args, &block)

      def content_type(value)
        app.response["Content-Type"] = value
      end

      def status(value)
        app.response.status = value
      end

      def flash(key, message)
        app.flash[key.to_s] = message
      end

      def flash_now(key, message)
        app.flash.now[key.to_s] = message
      end

      def not_found(message = "Not found")
        app.response.status = 404
        message
      end

      # Forwards app-provided helpers to the Roda app instance. Keyword
      # arguments are forwarded too, so `app_helper(preserve: ["cart"])` reaches
      # the helper as keywords instead of a positional Hash.
      def method_missing(name, *args, **kwargs, &block)
        return super unless app.respond_to?(name)

        app.public_send(name, *args, **kwargs, &block)
      end

      def respond_to_missing?(name, include_private = false)
        app.respond_to?(name) || super
      end
    end
  end
end
