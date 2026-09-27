# frozen_string_literal: true

require "stringio"
require_relative "rack_utils"

# Raised by Request#halt / Request#redirect to unwind to the dispatcher.
class Halt < StandardError
  attr_reader :status, :body

  def initialize(status, body)
    @status = status
    @body   = body
    super("halt")
  end
end

# Rack-lite request. Only the surface this app uses.
class Request
  attr_accessor :response
  attr_reader :headers

  def initialize(method, path, query = "", body = "", headers = {})
    @request_method                                         = method.to_s.upcase
    @path_info                                              = path
    @query_string                                           = query
    @raw_body                                               = body
    @headers                                                = {}
    headers.each { |key, value| @headers[key.to_s.downcase] = value }
    @params                                                 = nil
    @body_io                                                = StringIO.new(body)
  end

  def request_method
    @request_method
  end

  def path_info
    @path_info
  end

  def path
    @path_info
  end

  def query_string
    @query_string
  end

  def body
    @body_io
  end

  def segments
    @path_info.split("/").reject { |segment| segment.empty? }
  end

  def ip
    header("x-forwarded-for") || "127.0.0.1"
  end

  def user_agent
    header("user-agent") || ""
  end

  def header(name)
    @headers[name.to_s.downcase]
  end

  def cookie(name)
    cookies[name]
  end

  def cookies
    @cookies ||= begin
      result = {}
      raw    = header("cookie").to_s
      raw.split(";").each do |pair|
        next if pair.strip.empty?

        key, value  = pair.strip.split("=", 2)
        result[key] = value.to_s
      end
      result
    end
  end

  def media_type
    header("content-type").to_s.split(";", 2).first.to_s.strip
  end

  def params
    @params ||= begin
      merged = Rack::Utils.parse_nested_query(@query_string)
      if form_body?
        Rack::Utils.parse_nested_query(@raw_body).each { |key, value| merged[key] = value }
      end
      if merged["_method"] && @request_method == "POST"
        @request_method = merged["_method"].to_s.upcase
      end
      merged
    end
  end

  # Matches Roda's `r.halt`.
  def halt(status, message = "")
    raise Halt.new(status, message)
  end

  # Sets the response and unwinds (Roda's `r.redirect`).
  def redirect(location, status = 302)
    response.redirect(location, status)
    raise Halt.new(nil, nil)
  end

  private

  def form_body?
    type = media_type
    type.empty? || type == "application/x-www-form-urlencoded"
  end
end
