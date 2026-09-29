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
    @path_info.split("/").reject { |segment| segment.empty? }.map { |segment| Rack::Utils.unescape_path(segment) }
  end

  def ip
    header("x-forwarded-for") || "127.0.0.1"
  end

  def user_agent
    header("user-agent") || ""
  end

  def referer
    header("referer") || header("referrer") || ""
  end

  def scheme
    header("x-forwarded-proto") || "http"
  end

  def host_with_port
    header("host") || "localhost"
  end

  def url
    query = @query_string.to_s.empty? ? "" : "?#{@query_string}"
    "#{scheme}://#{host_with_port}#{path_info}#{query}"
  end

  def header(name)
    @headers[name.to_s.downcase]
  end

  # The Roda/Rack env: the lowered request keeps headers like a Rack env, and
  # the app's `Rack::Auth::Basic::Request.new(request.env)` path reads them.
  def env
    @headers
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

  # Full Content-Type header, parameters included (Rack::Request#content_type).
  # The upload endpoints read this to pick the MIME they validate/convert.
  def content_type
    value = header("content-type")
    value.nil? || value.empty? ? nil : value
  end

  def media_type
    header("content-type").to_s.split(";", 2).first.to_s.strip.downcase
  end

  def params
    @params ||= begin
      merged = Rack::Utils.parse_nested_query(@query_string)
      if multipart_body?
        merge_multipart(merged)
      elsif form_body?
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

  def multipart_body?
    media_type == "multipart/form-data"
  end

  # Parses a `multipart/form-data` body into `params`, Rack-style: text fields
  # become Strings and file fields become a Hash with :filename, :type, :name,
  # :tempfile (a StringIO) and :head. Field names go through the same nested
  # parser as a query string, so `foo[]`/`foo[bar]` names work. Without this,
  # multipart forms (file uploads) lost `_csrf`/`_method`, so every save was
  # rejected by an app's CSRF check.
  def merge_multipart(merged)
    delimiter = boundary
    return if delimiter.nil? || delimiter.empty?

    @raw_body.split("--#{delimiter}").each do |part|
      next if part.empty? || part.start_with?("--")

      part  = part[2, part.length].to_s if part.start_with?("\r\n")
      split = part.index("\r\n\r\n")
      next if split.nil?

      raw_headers = part[0, split]
      content     = part[(split + 4), part.length].to_s
      content     = content[0, content.length - 2] if content.end_with?("\r\n")

      name = raw_headers[/name="([^"]*)"/, 1]
      next if name.nil? || name.empty?

      # An empty `filename=""` part is an "input with no file chosen"
      # (Firefox sends these); Rack drops it, so skip it instead of treating it
      # as a zero-extension upload.
      filename = raw_headers[/filename="([^"]*)"/, 1]
      next if filename && filename.empty?

      Rack::Utils.normalize(merged, name, multipart_value(raw_headers, name, content, filename), 0)
    end
  end

  def multipart_value(raw_headers, name, content, filename)
    return content if filename.nil?

    {
      filename: filename,
      type:     raw_headers[/content-type:\s*([^\r\n]+)/i, 1].to_s.strip,
      name:     name,
      tempfile: StringIO.new(content),
      head:     raw_headers
    }
  end

  def boundary
    match = header("content-type").to_s.match(/boundary=(.+)/)
    return nil unless match

    value = match[1].strip
    value = value[1, value.length - 2] if value.start_with?('"') && value.end_with?('"') && value.length >= 2
    value
  end
end
