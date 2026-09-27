# frozen_string_literal: true

require_relative "../test_helper"
require "socket"

class HTTPTest < Minitest::Test
  def setup
    @server   = TCPServer.new("127.0.0.1", 0)
    @port     = @server.addr[1]
    @requests = Queue.new
    @thread   = Thread.new { serve }
  end

  def teardown
    @server.close
    @thread.kill
  end

  def url = "http://127.0.0.1:#{@port}"

  def test_supports_every_http_method
    Izen::HTTP::METHODS.each do |verb|
      response = Izen::HTTP.public_send(verb, "#{url}/#{verb}")

      assert_equal "200", response.code
      assert_equal "#{verb.to_s.upcase} /#{verb} HTTP/1.1", last_request[:line]
    end
  end

  def test_post_sends_json_body_and_content_type
    Izen::HTTP.post("#{url}/x", json: { "a" => 1, "b" => [ 2, 3 ] })

    request = last_request
    assert_equal '{"a":1,"b":[2,3]}', request[:body]
    assert_equal "application/json", request[:headers]["content-type"]
  end

  def test_params_are_appended_to_the_query_string
    Izen::HTTP.get("#{url}/search", params: { "q" => "kopi susu", "page" => 2 })

    assert_includes last_request[:line], "q=kopi+susu&page=2"
  end

  def test_headers_are_merged
    Izen::HTTP.new(headers: { "X-Base" => "base" }).get("#{url}/x", headers: { "Authorization" => "Bearer t" })

    request = last_request
    assert_equal "base", request[:headers]["x-base"]
    assert_equal "Bearer t", request[:headers]["authorization"]
  end

  def test_unsupported_method_raises
    assert_raises(ArgumentError) { Izen::HTTP.request(:brew, "#{url}/x") }
  end

  private

  def last_request
    @requests.pop
  end

  def serve
    loop do
      socket       = @server.accept
      request_line = socket.gets
      headers      = {}
      while (line  = socket.gets) && line != "\r\n"
        name, value                  = line.split(":", 2)
        headers[name.strip.downcase] = value.to_s.strip
      end
      body         = headers["content-length"] ? socket.read(headers["content-length"].to_i) : ""

      @requests << { line: request_line.to_s.strip, headers: headers, body: body }
      socket.write("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\n\r\nOK")
      socket.close
    end
  rescue IOError, Errno::EBADF
    nil
  end
end
