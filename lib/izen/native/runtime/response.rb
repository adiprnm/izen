# frozen_string_literal: true

# Rack-lite response.
class Response
  attr_accessor :status, :body
  attr_reader :headers

  def initialize
    @status  = 200
    @headers = {}
    @body    = ""
  end

  def [](key)
    @headers[key]
  end

  def []=(key, value)
    @headers[key] = value
  end

  def redirect(location, status = 302)
    @status              = status
    @headers["Location"] = location
    @body                = ""
  end

  # Rack::Response#write appends to the body; helpers that build a response
  # incrementally (e.g. `json_response(401, ...)`) rely on it.
  def write(chunk)
    text  = chunk.to_s
    @body = "#{@body}#{text}"
    text
  end
end
