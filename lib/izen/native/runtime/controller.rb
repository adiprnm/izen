# frozen_string_literal: true

module Base
  # Base controller, lowered from `Izen::Base::Controller`.
  #
  # Controllers receive the generated App instance and delegate rendering and
  # request context to it. App-specific helpers are reached through
  # `method_missing`, which forwards to the App (so this class stays generic).
  class Controller
    attr_reader :app

    def initialize(app)
      @app = app
    end

    private

    def render(template, locals = {}, layout: nil, **kwargs)
      locals = locals.merge(kwargs)
      app.view(template, locals: locals)
    end

    def session = app.session
    def params = app.request.params
    def request = app.request
    def response = app.response
    def h(text) = app.h(text)

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

    # Forwards app-provided helpers to the App instance.
    def method_missing(name, *args, &block)
      return super unless app.respond_to?(name)

      app.public_send(name, *args, &block)
    end

    def respond_to_missing?(name, include_private = false)
      app.respond_to?(name) || super
    end
  end
end
