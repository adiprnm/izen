# frozen_string_literal: true

require_relative "base64"
require_relative "secure_random"
require_relative "rack_utils"

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

  # The generated route table calls this guard on every non-`/api/` request
  # (mirroring `check_csrf! unless r.path_info.start_with?("/api/")` in
  # `app.rb`), so this is where the native server enforces CSRF. It matches the
  # app's `plugin :route_csrf, field: "authenticity_token", check_header: true,
  # require_request_specific_tokens: false`: safe methods pass, otherwise the
  # token must arrive as the hidden field (`_csrf`, the name `csrf_field`
  # emits, or `authenticity_token`) or the `X-CSRF-Token` header and equal the
  # session token. Failure halts with an empty 403 (`csrf_failure: :empty_403`).
  def check_csrf!
    method = request.request_method
    return if method == "GET" || method == "HEAD" || method == "OPTIONS" || method == "TRACE"

    expected = session["csrf"].to_s
    provided = (params["_csrf"] || params["authenticity_token"] || request.header("x-csrf-token")).to_s
    return if !expected.empty? && !provided.empty? && Rack::Utils.secure_compare(expected, provided)

    request.halt(403, "")
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

  # Liveness/readiness probe, mirroring `Izen::Application#health`. Expose it
  # with `r.get("health") { health }` in app.rb.
  def health
    database  = Database.connection.get_first_value("SELECT 1") == 1 ? "ok" : "error"
    migration = Database.connection.get_first_value("SELECT MAX(version) FROM schema_migrations")
    result    = {
      "status"    => database == "ok" ? "ok" : "degraded",
      "database"  => database,
      "migration" => migration
    }

    response["content-type"] = "application/json; charset=utf-8"
    response.status          = database == "ok" ? 200 : 503
    SessionCodec.generate_json(result)
  rescue StandardError => error
    response["content-type"] = "application/json; charset=utf-8"
    response.status          = 503
    SessionCodec.generate_json({ "status" => "error", "database" => "error", "error" => error.class.name })
  end
end
