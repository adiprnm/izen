# frozen_string_literal: true

require "socket"

# Minimal HTTP/1.1 server: one green thread per connection. Under Spinel this
# runs on the runtime's own scheduler (Thread is M:N, no GVL); on CRuby it is a
# plain thread. Replaces Puma.
#
# Shutdown: SIGTERM/SIGINT close the listener (which unblocks `accept`), wait
# up to GRACE seconds for in-flight requests, then close the SQLite connection
# so the WAL is checkpointed. This is what lets Kamal stop the container
# cleanly instead of killing it mid-request.
#
# Note: the accepted socket is captured by a method-local and passed to
# `serve`, rather than handed to the thread as a block argument. Spinel types a
# Thread block parameter too loosely to resolve socket methods like `gets` on
# it; a method parameter typed from the call site does resolve.
module Server
  STATUS_TEXT = {
    200 => "OK", 201 => "Created", 204 => "No Content", 302 => "Found",
    401 => "Unauthorized", 403 => "Forbidden", 404 => "Not Found",
    422 => "Unprocessable Entity", 429 => "Too Many Requests",
    500 => "Internal Server Error"
  }.freeze

  GRACE = 5 # seconds to let in-flight requests finish on shutdown

  @running  = true
  @active   = 0
  @mutex    = Mutex.new
  @listener = nil

  module_function

  def run(port = ENV.fetch("PORT", "3000").to_i)
    Database.connection # create the db dir + enable WAL once, before workers
    @running  = true
    @listener = TCPServer.new("0.0.0.0", port)
    set_nodelay(@listener)
    install_signal_handlers
    $stderr.puts("listening on 0.0.0.0:#{port}")

    begin
      while @running
        track_and_serve(@listener.accept)
      end
    rescue StandardError
      # The signal handler closed the listener out from under `accept`.
    end

    shutdown
  end

  def install_signal_handlers
    %w[TERM INT].each do |signal|
      begin
        Signal.trap(signal) { stop! }
      rescue ArgumentError
        # Signal not available on this platform; skip it.
      end
    end
  end

  # Called from the signal handler: stop accepting and wake the accept loop.
  def stop!
    @running = false
    listener = @listener
    return unless listener

    begin
      listener.close
    rescue StandardError
      nil
    end
  end

  # Disable Nagle on every connection. The response is written in a single
  # `write` below, but keep this too: without TCP_NODELAY a split write plus
  # the peer's delayed ACK stalls each keep-alive request by tens of ms.
  def set_nodelay(socket)
    socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
  rescue StandardError
    nil
  end

  def track_and_serve(socket)
    set_nodelay(socket)
    @mutex.synchronize { @active += 1 }
    Thread.new do
      begin
        serve(socket)
      ensure
        @mutex.synchronize { @active -= 1 }
      end
    end
  end

  def serve(socket)
    loop do
      request = read_request(socket)
      break unless request

      response = StaticFile.serve(request) || App.new.call(request)
      write_response(socket, response)
      break unless keep_alive?(request)
    end
  rescue StandardError => error
    $stderr.puts("server error: #{error.message}")
  ensure
    socket.close
    Database.disconnect # close this worker thread's SQLite connection
  end

  def shutdown
    deadline = Time.now + GRACE
    while active_connections.positive? && Time.now < deadline
      sleep 0.05
    end
    Database.disconnect
    $stderr.puts("shutdown complete")
  end

  def active_connections
    @mutex.synchronize { @active }
  end

  def read_request(socket)
    line = socket.gets
    return nil unless line

    method, target, = line.split(" ")
    path, query     = target.to_s.split("?", 2)
    headers         = {}
    while (raw      = socket.gets)
      raw = raw.strip
      break if raw.empty?

      key, value        = raw.split(":", 2)
      headers[key.to_s] = value.to_s.strip
    end

    length = headers["Content-Length"].to_i
    body   = length.positive? ? socket.read(length).to_s : ""
    Request.new(method, path, query.to_s, body, headers)
  end

  def write_response(socket, response)
    body   = response.body.to_s
    status = response.status
    out    = "".dup
    out << "HTTP/1.1 #{status} #{STATUS_TEXT.fetch(status, "OK")}\r\n"
    response.headers.each do |key, value|
      next if key == "Content-Length"

      out << "#{key}: #{value}\r\n"
    end
    out << "Content-Type: text/html; charset=utf-8\r\n" unless response.headers["Content-Type"]
    out << "Content-Length: #{body.bytesize}\r\n"
    out << "Connection: keep-alive\r\n"
    out << "\r\n"
    out << body
    # One syscall per response: the previous per-header writes let Nagle hold
    # the header block back until the ACK for the status line arrived.
    socket.write(out)
  end

  def keep_alive?(request)
    connection = request.header("connection").to_s.downcase
    connection != "close"
  end
end
