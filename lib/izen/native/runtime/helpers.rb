# frozen_string_literal: true

require_relative "base64"
require_relative "secure_random"

# Generic view helpers for the generated application. The render scope is the
# App instance, so templates and controllers share these methods. App-specific
# helpers live in the generated AppHelpers module.
module Helpers
  def h(text)
    Rack::Utils.escape_html(text.to_s)
  end

  def params
    request.params
  end

  def csrf_token
    session["csrf"] ||= SecureRandom.hex(32)
  end

  def csrf_field
    %(<input type="hidden" name="_csrf" value="#{h csrf_token}">)
  end

  # Roda's route_csrf names its hidden field helper `csrf_tag`; the copied
  # `csrf_token_field` view helper calls it.
  def csrf_tag
    csrf_field
  end

  def csrf_meta_tag
    %(<meta name="csrf-token" content="#{h csrf_token}">)
  end

  # The native server enforces CSRF; the generated route table still calls this
  # guard, so provide a no-op (Roda's :route_csrf plugin does the real work on
  # CRuby).
  def check_csrf!
    nil
  end

  # Roda's render: like `view` but without the layout (htmx fragments).
  def render(template, locals: {}, **kwargs)
    view(template, locals: locals.merge(kwargs), layout: false)
  end

  def simple_format(text)
    escaped = h(text)
    escaped.split(/\n{2,}/).map { |block| "<p>#{block.gsub("\n", "<br>")}</p>" }.join
  end

  def format_datetime(time)
    time&.getlocal&.strftime("%d/%m/%Y %H:%M")
  end
end
