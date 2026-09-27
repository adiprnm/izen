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
end
