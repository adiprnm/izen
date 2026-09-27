# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

# Small HTTP client built on Net::HTTP that supports every HTTP method.
#
#   HTTP.get("https://example.com")
#   HTTP.post("https://api.example.com/v1/x",
#             json:    { a: 1 },
#             headers: { "Authorization" => "Bearer token" })
#   HTTP.new(open_timeout: 30, read_timeout: 600).put(url, body: "raw")
#
# Returns the raw `Net::HTTPResponse` (use #code, #body, #[]).
module Izen
  class HTTP
    METHODS              = %i[get head post put patch delete options trace].freeze
    DEFAULT_OPEN_TIMEOUT = 30
    DEFAULT_READ_TIMEOUT = 60

    class << self
      METHODS.each do |verb|
        define_method(verb) do |url, **options|
          request(verb, url, **options)
        end
      end

      def request(verb, url, **options)
        new(**options.slice(:open_timeout, :read_timeout))
          .request(verb, url, **options.except(:open_timeout, :read_timeout))
      end
    end

    def initialize(open_timeout: DEFAULT_OPEN_TIMEOUT, read_timeout: DEFAULT_READ_TIMEOUT, headers: {})
      @open_timeout = open_timeout
      @read_timeout = read_timeout
      @headers      = headers
    end

    METHODS.each do |verb|
      define_method(verb) do |url, **options|
        request(verb, url, **options)
      end
    end

    def request(verb, url, headers: {}, params: nil, body: nil, json: nil)
      verb = verb.to_s.downcase.to_sym
      raise ArgumentError, "unsupported HTTP method: #{verb}" unless METHODS.include?(verb)

      uri       = URI.parse(url.to_s)
      uri.query = URI.encode_www_form(params) if params && !params.empty?

      build_http(uri).request(build_request(verb, uri, headers, body, json))
    end

    private

    def build_request(verb, uri, headers, body, json)
      request                                                    = Net::HTTP.const_get(verb.to_s.capitalize).new(uri)
      @headers.merge(headers).each { |name, value| request[name] = value }

      if json
        request["Content-Type"] ||= "application/json"
        request["Accept"]       ||= "application/json"
        request.body              = JSON.generate(json)
      elsif body
        request.body = body
      end

      request
    end

    def build_http(uri)
      http              = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl      = (uri.scheme == "https")
      http.open_timeout = @open_timeout
      http.read_timeout = @read_timeout
      http
    end
  end
end
