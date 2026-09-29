# frozen_string_literal: true

require "stringio"
require "uri"
require "socket"
require "openssl"
require "base64"

# Implementations of the third-party libraries the source app uses, written in
# the subset Spinel can compile. They implement the surface the app calls: SMTP
# delivery, HTTPS + AWS SigV4 (R2), AES-256-GCM, HTML allowlist sanitizing,
# image conversion through the `vips` CLI, and a real background scheduler. A
# feature only degrades (with a logged warning) when the underlying tool is
# genuinely absent at runtime.

# --- Rack extras (Rack::Utils lives in rack_utils.rb) ----------------------

module Rack
  module Mime
    TYPES = {
      ".css"  => "text/css",
      ".js"   => "application/javascript",
      ".mjs"  => "application/javascript",
      ".json" => "application/json",
      ".txt"  => "text/plain",
      ".svg"  => "image/svg+xml",
      ".png"  => "image/png",
      ".jpg"  => "image/jpeg",
      ".jpeg" => "image/jpeg",
      ".gif"  => "image/gif",
      ".webp" => "image/webp",
      ".ico"  => "image/x-icon",
      ".pdf"  => "application/pdf",
      ".mp4"  => "video/mp4",
      ".webm" => "video/webm",
      ".mp3"  => "audio/mpeg",
      ".ogg"  => "audio/ogg"
    }.freeze

    module_function

    def mime_type(extension, fallback = "application/octet-stream")
      TYPES[extension.to_s.downcase] || fallback
    end
  end

  module Auth
    module Basic
      class Request
        def initialize(env)
          @env = env || {}
        end

        def authorization
          value = @env["authorization"]
          value = @env["HTTP_AUTHORIZATION"] if value.nil?
          value.to_s
        end

        def provided?
          !authorization.empty?
        end

        def basic?
          authorization.start_with?("Basic ")
        end

        def credentials
          return [ nil, nil ] unless basic?

          decoded        = Base64Url.decode(authorization.sub("Basic ", "").strip)
          user, password = decoded.split(":", 2)
          [ user, password ]
        end
      end
    end
  end
end

# --- Sanitize ---------------------------------------------------------------

# HTML allowlist sanitizer, rounding out `Sanitize.fragment` for the native
# build (no Nokogiri). The allowlists mirror the `sanitize` gem's
# RESTRICTED/BASIC/RELAXED configs; `Sanitizer` walks the markup as a string
# and keeps only allowed elements/attributes, validating URL protocols after
# decoding entities (so `java&#115;cript:` and friends cannot slip through).
module Sanitize
  class Config
    RESTRICTED = {
      elements: %w[b em i strong u]
    }.freeze

    BASIC = {
      elements:   RESTRICTED[:elements] + %w[
        a abbr blockquote br cite code dd dfn dl dt kbd li mark ol p pre q s
        samp small strike sub sup time ul var
      ],
      attributes: {
        "a"          => %w[href],
        "abbr"       => %w[title],
        "blockquote" => %w[cite],
        "dfn"        => %w[title],
        "q"          => %w[cite],
        "time"       => %w[datetime pubdate]
      },
      protocols:  {
        "a"          => { "href" => %w[ftp http https mailto relative] },
        "blockquote" => { "cite" => %w[http https relative] },
        "q"          => { "cite" => %w[http https relative] }
      }
    }.freeze

    RELAXED = {
      elements:   BASIC[:elements] + %w[
        address article aside bdi bdo body caption col colgroup data del div
        figcaption figure footer h1 h2 h3 h4 h5 h6 head header hgroup hr html
        img ins main nav rp rt ruby section span style summary table tbody td
        tfoot th thead title tr wbr
      ],
      attributes: {
        all: %w[class dir hidden id lang style tabindex title translate],
        "a" => %w[href hreflang name rel],
        "abbr" => %w[title],
        "blockquote" => %w[cite],
        "col" => %w[span width],
        "colgroup" => %w[span width],
        "data" => %w[value],
        "del" => %w[cite datetime],
        "dfn" => %w[title],
        "img" => %w[align alt border height src srcset width],
        "ins" => %w[cite datetime],
        "li" => %w[value],
        "ol" => %w[reversed start type],
        "q" => %w[cite],
        "style" => %w[media scoped type],
        "table" => %w[align bgcolor border cellpadding cellspacing frame rules sortable summary width],
        "td" => %w[abbr align axis colspan headers rowspan valign width],
        "th" => %w[abbr align axis colspan headers rowspan scope sorted valign width],
        "time" => %w[datetime pubdate],
        "ul" => %w[type]
      },
      protocols:  {
        "a"          => { "href" => %w[ftp http https mailto relative] },
        "blockquote" => { "cite" => %w[http https relative] },
        "del"        => { "cite" => %w[http https relative] },
        "img"        => { "src" => %w[http https relative] },
        "ins"        => { "cite" => %w[http https relative] },
        "q"          => { "cite" => %w[http https relative] }
      }
    }.freeze

    class << self
      def merge(*configs, **options)
        merged                                                         = {}
        configs.each { |config| config.each { |key, value| merged[key] = value } }
        options.each { |key, value| merged[key]                        = value }
        merged
      end
    end
  end

  module_function

  def fragment(html, config = nil)
    Sanitizer.new(config || Config::RELAXED).sanitize(html.to_s)
  end

  def document(html, config = nil)
    fragment(html, config)
  end

  def clean(html, config = nil)
    fragment(html, config)
  end

  class Sanitizer
    VOID_ELEMENTS  = %w[
      area base br col embed hr img input link meta param source track wbr
    ].freeze
    DROP_CONTENT   = %w[
      script style iframe object embed noscript template svg math canvas form
      applet frame frameset
    ].freeze
    URL_ATTRIBUTES = %w[
      href src cite action formaction poster background data srcset
    ].freeze
    ENTITIES       = {
      "amp" => "&", "lt" => "<", "gt" => ">", "quot" => '"', "apos" => "'",
      "colon" => ":", "sol" => "/", "Tab" => "\t", "NewLine" => "\n"
    }.freeze
    HEX            = "0123456789abcdef"

    def initialize(config)
      @allowed_elements                                               = {}
      (config[:elements] || []).each { |name| @allowed_elements[name] = true }
      @attributes                                                     = config[:attributes] || {}
      @protocols                                                      = config[:protocols] || {}
    end

    def sanitize(html)
      out  = "".dup
      pos  = 0
      size = html.length

      while pos < size
        lt = html.index("<", pos)
        unless lt
          out << html[pos, size - pos]
          break
        end

        out << html[pos, lt - pos]

        if html[lt + 1] == "!" && html[lt + 2, 2] == "--"
          stop = html.index("-->", lt)
          break if stop.nil?

          pos = stop + 3
          next
        end
        if html[lt + 1] == "!" || html[lt + 1] == "?"
          gt = html.index(">", lt)
          break if gt.nil?

          pos = gt + 1
          next
        end

        tag = scan_tag(html, lt)
        if tag.nil?
          out << "&lt;"
          pos = lt + 1
          next
        end

        _start, stop, name, closing, self_closing, attrs = tag
        down                                             = name.downcase
        if down.empty?
          pos = stop
          next
        end

        if @allowed_elements[down]
          out << (closing ? "</#{down}>" : open_tag(down, attrs, self_closing))
          pos = stop
        elsif DROP_CONTENT.include?(down)
          close = find_close(html, stop, down)
          pos   = close ? close[1] : stop
        else
          pos = stop
        end
      end

      out
    end

    private

    def open_tag(name, attrs, self_closing)
      allowed = allowed_attributes(name)
      kept    = []

      parse_attributes(attrs) do |attr_name, attr_value|
        key = attr_name.downcase
        next unless allowed.include?(key)
        next if key.start_with?("on")
        next if URL_ATTRIBUTES.include?(key) && !url_allowed?(name, key, attr_value)

        kept << "#{key}=\"#{escape(decode(attr_value))}\""
      end

      tag = "".dup
      tag << "<#{name}"
      kept.each { |pair| tag << " " << pair }
      tag << "/" if self_closing && !VOID_ELEMENTS.include?(name)
      tag << ">"
      tag
    end

    def allowed_attributes(name)
      list      = []
      (all      = @attributes[:all]) && list.concat(all)
      (specific = @attributes[name]) && list.concat(specific)
      list
    end

    def url_allowed?(element, attribute, value)
      protocols   = @protocols[element] && @protocols[element][attribute]
      protocols ||= %w[http https mailto ftp relative]
      return true if protocols.include?("relative") && relative?(value)

      scheme = scheme_of(value)
      !scheme.nil? && protocols.include?(scheme)
    end

    def relative?(value)
      scheme_of(value).nil?
    end

    def scheme_of(value)
      cleaned = "".dup
      decode(value).each_byte { |byte| cleaned << byte.chr if byte > 0x20 && byte != 0x7F }
      match = cleaned.match(/\A([a-zA-Z][a-zA-Z0-9+.\-]*):/)
      match ? match[1].downcase : nil
    end

    def parse_attributes(attrs)
      pos  = 0
      size = attrs.length
      while pos < size
        pos += 1 while pos < size && whitespace?(attrs[pos])
        break if pos >= size

        start = pos
        pos  += 1 while pos < size && !whitespace?(attrs[pos]) && attrs[pos] != "="
        name  = attrs[start, pos - start]
        pos  += 1 while pos < size && whitespace?(attrs[pos])

        value = ""
        if pos < size && attrs[pos] == "="
          pos += 1
          pos += 1 while pos < size && whitespace?(attrs[pos])
          if pos < size && (attrs[pos] == '"' || attrs[pos] == "'")
            quote  = attrs[pos]
            pos   += 1
            vstart = pos
            pos   += 1 while pos < size && attrs[pos] != quote
            value  = attrs[vstart, pos - vstart]
            pos   += 1
          else
            vstart = pos
            pos   += 1 while pos < size && !whitespace?(attrs[pos])
            value  = attrs[vstart, pos - vstart]
          end
        end

        yield(name, value) unless name.empty?
      end
    end

    def scan_tag(html, start)
      size    = html.length
      i       = start + 1
      closing = false
      if html[i] == "/"
        closing = true
        i      += 1
      end

      j  = i
      j += 1 while j < size && tag_name_char?(html[j])
      return nil if j == i

      name  = html[i, j - i]
      k     = j
      quote = nil
      while k < size
        c = html[k]
        if quote
          quote = nil if c == quote
        elsif c == '"' || c == "'"
          quote = c
        elsif c == ">"
          break
        end
        k += 1
      end
      return nil if k >= size

      attrs        = html[j, k - j]
      trimmed      = attrs.rstrip
      self_closing = trimmed.end_with?("/")
      attrs        = trimmed[0, trimmed.length - 1] if self_closing
      [ start, k + 1, name, closing, self_closing, attrs ]
    end

    def find_close(html, from, name)
      depth = 0
      pos   = from
      size  = html.length
      while pos < size
        lt = html.index("<", pos)
        return nil if lt.nil?

        tag = scan_tag(html, lt)
        if tag.nil?
          pos = lt + 1
          next
        end

        _start, stop, tag_name, closing, self_closing, _attrs = tag
        pos                                                   = stop
        next unless tag_name.downcase == name

        if closing
          return [ stop, stop ] if depth.zero?

          depth -= 1
        elsif !self_closing
          depth += 1
        end
      end
      nil
    end

    def whitespace?(char)
      char == " " || char == "\t" || char == "\n" || char == "\r" || char == "\f"
    end

    def tag_name_char?(char)
      return false if char.nil?

      (char >= "a" && char <= "z") || (char >= "A" && char <= "Z") ||
        (char >= "0" && char <= "9") || char == ":" || char == "-"
    end

    def decode(value)
      text = value.to_s
      return text unless text.include?("&")

      out  = "".dup
      pos  = 0
      size = text.length
      while pos < size
        if text[pos] == "&" && (semi = text.index(";", pos)) && semi - pos <= 10
          entity  = text[pos + 1, semi - pos - 1]
          decoded = decode_entity(entity)
          if decoded
            out << decoded
            pos = semi + 1
            next
          end
        end
        out << text[pos]
        pos += 1
      end
      out
    end

    def decode_entity(entity)
      return ENTITIES[entity] if ENTITIES.key?(entity)
      if entity.start_with?("#x", "#X")
        code_point(entity[2, entity.length], 16)
      elsif entity.start_with?("#")
        code_point(entity[1, entity.length], 10)
      end
    end

    def code_point(digits, base)
      return nil if digits.empty?

      alphabet = base == 16 ? HEX : "0123456789"
      value    = 0
      digits.downcase.each_char do |char|
        digit = alphabet.index(char)
        return nil if digit.nil? || digit >= base

        value = value * base + digit
      end
      value.positive? && value <= 0x10FFFF ? value.chr(Encoding::UTF_8) : nil
    end

    def escape(value)
      text = value.to_s
      out  = "".dup
      text.each_char do |char|
        case char
        when "&" then out << "&amp;"
        when "<" then out << "&lt;"
        when ">" then out << "&gt;"
        when '"' then out << "&quot;"
        else out << char
        end
      end
      out
    end
  end
end

# --- Mail (SMTP delivery) ---------------------------------------------------

module Mail
  class Message
    class << self
      attr_accessor :deliveries
    end
    self.deliveries = []

    attr_accessor :from, :to, :subject, :body, :content_type

    def initialize
      @delivery_method  = :smtp
      @delivery_options = {}
    end

    def delivery_method(name, options = nil)
      @delivery_method  = name
      @delivery_options = options || {}
    end

    def deliver
      if @delivery_method == :test
        Message.deliveries << self
        return self
      end

      SMTP.new(@delivery_options).deliver(self)
      self
    end

    def to_s
      body.to_s
    end
  end

  def self.new
    Message.new
  end

  class TestMailer
    def self.deliveries
      Message.deliveries
    end
  end

  # Minimal SMTP client: TCP, implicit TLS (port 465) or STARTTLS (587),
  # AUTH PLAIN / LOGIN, and a dot-stuffed DATA phase. Enough for the
  # transactional mail this app sends.
  class SMTP
    def initialize(options)
      @address  = option(options, :address, "localhost").to_s
      @port     = option(options, :port, 587).to_i
      @user     = option(options, :user_name, "").to_s
      @password = option(options, :password, "").to_s
      @auth     = option(options, :authentication, "plain").to_s
    end

    def deliver(message)
      raw        = build_raw(message)
      from       = extract_address(message.from)
      recipients = split_addresses(message.to)

      socket = TCPSocket.new(@address, @port)
      if @port == 465
        ssl = tls_wrap(socket)
        read_reply_tls(ssl, 220)
        ehlo_tls(ssl)
        return transact_tls(ssl, raw, from, recipients)
      end

      read_reply_plain(socket, 220)
      capabilities = ehlo_plain(socket)
      if capabilities.include?("STARTTLS")
        write_plain(socket, "STARTTLS\r\n")
        read_reply_plain(socket, 220)
        ssl = tls_wrap(socket)
        ehlo_tls(ssl)
        return transact_tls(ssl, raw, from, recipients)
      end

      transact_plain(socket, raw, from, recipients)
    end

    private

    def option(options, key, fallback)
      options.key?(key) ? options[key] : fallback
    end

    def tls_wrap(socket)
      context        = OpenSSL::SSL::SSLContext.new
      context.set_params
      ssl            = OpenSSL::SSL::SSLSocket.new(socket, context)
      ssl.hostname   = @address
      ssl.sync_close = true
      ssl.connect
      ssl
    end

    # --- plain path ------------------------------------------------------

    def read_reply_plain(socket, expected)
      lines = []
      loop do
        line = socket.gets
        raise "SMTP connection closed" if line.nil?

        line = line.chomp
        lines << line
        break unless line.length >= 4 && line[3] == "-"
      end
      code = lines.last[0, 3].to_i
      raise "SMTP error #{code}: #{lines.join(' ')}" unless code == expected

      lines
    end

    def write_plain(socket, data)
      socket.write(data)
    end

    def ehlo_plain(socket)
      write_plain(socket, "EHLO #{Socket.gethostname}\r\n")
      read_reply_plain(socket, 250).join("\n")
    end

    def authenticate_plain(socket)
      if @auth == "login"
        write_plain(socket, "AUTH LOGIN\r\n")
        read_reply_plain(socket, 334)
        write_plain(socket, "#{Base64.strict_encode64(@user)}\r\n")
        read_reply_plain(socket, 334)
        write_plain(socket, "#{Base64.strict_encode64(@password)}\r\n")
        read_reply_plain(socket, 235)
      else
        write_plain(socket, "AUTH PLAIN #{Base64.strict_encode64("\0#{@user}\0#{@password}")}\r\n")
        read_reply_plain(socket, 235)
      end
    end

    def transact_plain(socket, raw, from, recipients)
      authenticate_plain(socket) unless @user.empty?
      write_plain(socket, "MAIL FROM:<#{from}>\r\n")
      read_reply_plain(socket, 250)
      recipients.each do |recipient|
        write_plain(socket, "RCPT TO:<#{recipient}>\r\n")
        read_reply_plain(socket, 250)
      end
      write_plain(socket, "DATA\r\n")
      read_reply_plain(socket, 354)
      write_plain(socket, dot_stuff(raw))
      write_plain(socket, "\r\n.\r\n")
      read_reply_plain(socket, 250)
      write_plain(socket, "QUIT\r\n")
      socket.close
      true
    end

    # --- TLS path --------------------------------------------------------

    def read_reply_tls(ssl, expected)
      lines = []
      loop do
        line = ssl.gets
        raise "SMTP connection closed" if line.nil?

        line = line.chomp
        lines << line
        break unless line.length >= 4 && line[3] == "-"
      end
      code = lines.last[0, 3].to_i
      raise "SMTP error #{code}: #{lines.join(' ')}" unless code == expected

      lines
    end

    def write_tls(ssl, data)
      ssl.write(data)
    end

    def ehlo_tls(ssl)
      write_tls(ssl, "EHLO #{Socket.gethostname}\r\n")
      read_reply_tls(ssl, 250).join("\n")
    end

    def authenticate_tls(ssl)
      if @auth == "login"
        write_tls(ssl, "AUTH LOGIN\r\n")
        read_reply_tls(ssl, 334)
        write_tls(ssl, "#{Base64.strict_encode64(@user)}\r\n")
        read_reply_tls(ssl, 334)
        write_tls(ssl, "#{Base64.strict_encode64(@password)}\r\n")
        read_reply_tls(ssl, 235)
      else
        write_tls(ssl, "AUTH PLAIN #{Base64.strict_encode64("\0#{@user}\0#{@password}")}\r\n")
        read_reply_tls(ssl, 235)
      end
    end

    def transact_tls(ssl, raw, from, recipients)
      authenticate_tls(ssl) unless @user.empty?
      write_tls(ssl, "MAIL FROM:<#{from}>\r\n")
      read_reply_tls(ssl, 250)
      recipients.each do |recipient|
        write_tls(ssl, "RCPT TO:<#{recipient}>\r\n")
        read_reply_tls(ssl, 250)
      end
      write_tls(ssl, "DATA\r\n")
      read_reply_tls(ssl, 354)
      write_tls(ssl, dot_stuff(raw))
      write_tls(ssl, "\r\n.\r\n")
      read_reply_tls(ssl, 250)
      write_tls(ssl, "QUIT\r\n")
      ssl.close
      true
    end

    # --- shared ----------------------------------------------------------

    def dot_stuff(raw)
      lines = raw.gsub("\r\n", "\n").gsub("\r", "\n").split("\n", -1)
      lines.map { |line| line.start_with?(".") ? ".#{line}" : line }.join("\r\n")
    end

    def build_raw(message)
      out = "".dup
      out << "From: #{message.from}\r\n"
      out << "To: #{message.to}\r\n"
      out << "Subject: #{message.subject}\r\n"
      out << "MIME-Version: 1.0\r\n"
      out << "Content-Type: #{message.content_type}\r\n"
      out << "\r\n"
      out << message.body.to_s
      out
    end

    def extract_address(value)
      text = value.to_s
      open = text.index("<")
      if open
        rest  = text[open + 1, text.length]
        close = rest.index(">")
        return rest[0, close] if close
      end
      text.strip
    end

    def split_addresses(value)
      value.to_s.split(",").map { |part| extract_address(part) }.reject { |address| address.empty? }
    end
  end
end

# --- Rufus::Scheduler -------------------------------------------------------

# A small real scheduler: entries are registered and a background thread fires
# those that are due (cron is matched minute-by-minute against the five-field
# expression). Replaces the earlier shim that ran a block the moment it was
# registered.
module Rufus
  class Scheduler
    POLL_SECONDS = 10
    SEARCH_LIMIT = 366 * 24 * 60

    def initialize
      @entries = []
      @running = false
      @mutex   = Mutex.new
    end

    def cron(expression, _options = nil, &block)
      add({ kind: "cron", fields: expression.to_s.split, block: block })
    end

    def every(interval, _options = nil, &block)
      seconds = parse_interval(interval)
      add({ kind: "every", seconds: seconds, block: block, next_at: Time.now + seconds })
    end

    def in(interval, _options = nil, &block)
      seconds = parse_interval(interval)
      add({ kind: "in", block: block, next_at: Time.now + seconds })
    end

    def shutdown
      @running = false
      nil
    end

    private

    def add(entry)
      entry[:next_at] ||= next_cron_time(entry[:fields], Time.now)
      @mutex.synchronize { @entries << entry }
      start
      nil
    end

    def start
      return if @running

      @running = true
      Thread.new do
        while @running
          sleep POLL_SECONDS
          run_due
        end
      end
    end

    def run_due
      now = Time.now
      due = []
      @mutex.synchronize do
        @entries.each do |entry|
          next if entry[:next_at].nil? || entry[:next_at] > now

          due << entry
          entry[:next_at] =
            if entry[:kind] == "in"
              nil
            elsif entry[:kind] == "every"
              now + entry[:seconds]
            else
              next_cron_time(entry[:fields], now)
            end
        end
      end

      due.each do |entry|
        next unless entry[:block]

        begin
          entry[:block].call
        rescue StandardError => e
          warn "[scheduler] #{e.class}: #{e.message}"
        end
      end
    end

    def parse_interval(interval)
      case interval
      when Integer then interval
      when Float then interval.to_i
      when String then interval.to_i
      else 60
      end
    end

    # Next time (UTC, minute granularity) the five-field cron expression
    # matches, scanning forward one minute at a time.
    def next_cron_time(fields, from)
      return from + 60 if fields.nil? || fields.length < 5

      time  = Time.utc(from.year, from.month, from.day, from.hour, from.min, 0) + 60
      limit = time + SEARCH_LIMIT * 60

      while time < limit
        if field_match?(fields[0], time.min) &&
           field_match?(fields[1], time.hour) &&
           field_match?(fields[2], time.day) &&
           field_match?(fields[3], time.month) &&
           field_match?(fields[4], time.strftime("%w").to_i)
          return time
        end
        time = time + 60
      end
      from + 86_400
    end

    # Supports `*`, `a`, `a-b`, `*/n`, `a-b/n` and comma lists.
    def field_match?(field, value)
      return true if field == "*"

      field.split(",").any? do |part|
        base = part
        step = 1
        if part.include?("/")
          pieces = part.split("/", 2)
          base   = pieces[0]
          step   = pieces[1].to_i
          step   = 1 if step <= 0
        end

        if base == "*"
          (value % step).zero?
        elsif base.include?("-")
          ends  = base.split("-", 2)
          first = ends[0].to_i
          last  = ends[1].to_i
          value >= first && value <= last && ((value - first) % step).zero?
        else
          base.to_i == value
        end
      end
    end
  end
end

# --- Minimal HTTP/1.1 client over TCP + TLS --------------------------------

# Enough of an HTTP client for signed S3 GET/PUT/DELETE (and anything else that
# speaks plain HTTP/1.1). Spinel carries no net/http, so this drives a socket
# directly the way the SMTP shim does.
module MiniHttp
  module_function

  def request(secure, host, port, method, path, headers, body)
    socket = TCPSocket.new(host, port)
    if secure
      context        = OpenSSL::SSL::SSLContext.new
      context.set_params
      ssl            = OpenSSL::SSL::SSLSocket.new(socket, context)
      ssl.hostname   = host
      ssl.sync_close = true
      ssl.connect
      socket         = ssl
    end

    head = +"#{method} #{path} HTTP/1.1\r\n"
    head << "host: #{host}\r\n" unless header?(headers, "host")
    headers.each { |key, value| head << "#{key}: #{value}\r\n" }
    if body && !body.to_s.empty? && !header?(headers, "content-length") && !header?(headers, "transfer-encoding")
      head << "content-length: #{body.to_s.bytesize}\r\n"
    end
    head << "connection: close\r\n\r\n"
    socket.write(head)
    socket.write(body) if body && !body.to_s.empty?

    parse_response(socket, method)
  ensure
    socket.close if socket
  end

  def header?(headers, name)
    found                          = false
    headers.each_key { |key| found = true if key.to_s.downcase == name }
    found
  end

  def parse_response(socket, method)
    parts   = socket.gets.to_s.split(" ", 3)
    status  = parts.length > 1 ? parts[1].to_i : 0
    headers = {}
    loop do
      line = socket.gets
      break if line.nil?

      line = line.chomp
      break if line.empty?

      colon = line.index(":")
      next unless colon

      headers[line[0, colon].downcase] = line[colon + 1, line.length].to_s.strip
    end

    body =
      if method == "HEAD"
        ""
      elsif headers["transfer-encoding"].to_s.downcase.include?("chunked")
        read_chunked(socket)
      elsif headers["content-length"]
        read_exact(socket, headers["content-length"].to_i)
      else
        read_all(socket)
      end

    [ status, headers, body ]
  end

  def read_exact(socket, count)
    buffer = "".dup
    while buffer.bytesize < count
      chunk = socket.read(count - buffer.bytesize)
      break if chunk.nil? || chunk.empty?

      buffer << chunk
    end
    buffer
  end

  def read_all(socket)
    buffer = "".dup
    loop do
      chunk = socket.read(65_536)
      break if chunk.nil? || chunk.empty?

      buffer << chunk
    end
    buffer
  end

  def read_chunked(socket)
    buffer = "".dup
    loop do
      size = socket.gets.to_s.strip.split(";", 2)[0].to_i(16)
      break if size.zero?

      buffer << read_exact(socket, size)
      socket.gets # trailing CRLF
    end
    buffer
  end
end

# --- AWS SigV4 (header auth) ------------------------------------------------

module AwsSigV4
  module_function

  # Returns the request headers to send, including `authorization`.
  def sign(access_key, secret_key, region, service, method, host, path, payload, content_type)
    now       = Time.now.utc
    amzdate   = now.strftime("%Y%m%dT%H%M%SZ")
    datestamp = now.strftime("%Y%m%d")

    headers                         = {}
    headers["host"]                 = host
    headers["x-amz-content-sha256"] = Crypto.sha256_hex(payload.to_s)
    headers["x-amz-date"]           = amzdate
    headers["content-type"]         = content_type if content_type

    names     = headers.keys.sort
    canonical = "".dup
    names.each { |name| canonical << "#{name}:#{headers[name]}\n" }
    signed    = names.join(";")

    canonical_request = "#{method}\n#{path}\n\n#{canonical}\n#{signed}\n#{headers["x-amz-content-sha256"]}"
    scope             = "#{datestamp}/#{region}/#{service}/aws4_request"
    string_to_sign    = "AWS4-HMAC-SHA256\n#{amzdate}\n#{scope}\n#{Crypto.sha256_hex(canonical_request)}"
    signature         = Crypto.hmac_sha256_hex(signing_key(secret_key, datestamp, region, service), string_to_sign)

    headers["authorization"] =
      "AWS4-HMAC-SHA256 Credential=#{access_key}/#{scope}, SignedHeaders=#{signed}, Signature=#{signature}"
    headers
  end

  def signing_key(secret, datestamp, region, service)
    date = Crypto.hmac_sha256("AWS4#{secret}", datestamp)
    area = Crypto.hmac_sha256(date, region)
    svc  = Crypto.hmac_sha256(area, service)
    Crypto.hmac_sha256(svc, "aws4_request")
  end

  # Query-string signed URL (SigV4 query auth) for a GET, valid for
  # `expires_in` seconds.
  def presign(access_key, secret_key, region, service, host, path, expires_in)
    now       = Time.now.utc
    amzdate   = now.strftime("%Y%m%dT%H%M%SZ")
    datestamp = now.strftime("%Y%m%d")
    scope     = "#{datestamp}/#{region}/#{service}/aws4_request"
    query     = "X-Amz-Algorithm=AWS4-HMAC-SHA256" \
                "&X-Amz-Credential=#{encode_component("#{access_key}/#{scope}")}" \
                "&X-Amz-Date=#{amzdate}" \
                "&X-Amz-Expires=#{expires_in.to_i}" \
                "&X-Amz-SignedHeaders=host"

    canonical_request = "GET\n#{path}\n#{query}\nhost:#{host}\n\nhost\nUNSIGNED-PAYLOAD"
    string_to_sign    = "AWS4-HMAC-SHA256\n#{amzdate}\n#{scope}\n#{Crypto.sha256_hex(canonical_request)}"
    signature         = Crypto.hmac_sha256_hex(signing_key(secret_key, datestamp, region, service), string_to_sign)

    "https://#{host}#{path}?#{query}&X-Amz-Signature=#{signature}"
  end

  def encode_component(value)
    out = "".dup
    value.to_s.bytes.each do |byte|
      if (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) ||
         (byte >= 48 && byte <= 57) || byte == 45 || byte == 95 || byte == 46 || byte == 126
        out << byte.chr
      else
        out << "%" << "0123456789ABCDEF"[byte >> 4] << "0123456789ABCDEF"[byte & 15]
      end
    end
    out
  end
end

# --- Aws::S3 ----------------------------------------------------------------

module Aws
  module Errors
    class ServiceError < StandardError; end
  end

  module S3
    module Errors
      class NoSuchKey < StandardError; end
      class NotFound < NoSuchKey; end
    end

    class Object
      attr_accessor :content_type, :content_length, :body
    end

    # Talks to R2 (or any S3-compatible endpoint) over real HTTP with SigV4
    # header auth. Only the operations this app calls are implemented.
    class Client
      HEX = "0123456789ABCDEF"

      def initialize(options = nil)
        options     = options || {}
        @endpoint   = options[:endpoint].to_s
        @access_key = options[:access_key_id].to_s
        @secret_key = options[:secret_access_key].to_s
        @region     = (options[:region] || "auto").to_s
      end

      def get_object(bucket:, key:)
        result = perform("GET", bucket, key, nil, nil)
        status = result[0]
        raise Errors::NoSuchKey, "NoSuchKey: #{key}" if status == 404
        raise Errors::ServiceError, "S3 GET #{status}" if status >= 400

        object                = Object.new
        object.content_type   = result[1]["content-type"] || "application/octet-stream"
        object.content_length = result[2].bytesize
        object.body           = StringIO.new(result[2])
        object
      end

      def put_object(bucket:, key:, content_type:, body:)
        status = perform("PUT", bucket, key, body, content_type)[0]
        raise Errors::ServiceError, "S3 PUT #{status}" if status >= 400

        true
      end

      def delete_object(bucket:, key:)
        status = perform("DELETE", bucket, key, "", nil)[0]
        raise Errors::ServiceError, "S3 DELETE #{status}" if status >= 400 && status != 404

        true
      end

      # Public URL with a SigV4 query signature, for handing a short-lived
      # download link to the browser.
      def presigned_url(bucket, key, expires_in)
        uri  = URI.parse(@endpoint)
        host = uri.host.to_s
        AwsSigV4.presign(
          @access_key,
          @secret_key,
          @region,
          "s3",
          host,
          "/#{encode_segment(bucket)}/#{encode_path(key)}",
          expires_in
        )
      end

      private

      def perform(method, bucket, key, body, content_type)
        uri  = URI.parse(@endpoint)
        host = uri.host.to_s
        port = uri.port || (uri.scheme == "https" ? 443 : 80)
        path = "/#{encode_segment(bucket)}/#{encode_path(key)}"
        meta = AwsSigV4.sign(@access_key, @secret_key, @region, "s3", method, host, path, body.to_s, content_type)
        MiniHttp.request(uri.scheme == "https", host, port, method, path, meta, body)
      end

      def encode_path(key)
        key.to_s.split("/", -1).map { |segment| encode_segment(segment) }.join("/")
      end

      def encode_segment(segment)
        out = "".dup
        segment.to_s.bytes.each do |byte|
          if unreserved?(byte)
            out << byte.chr
          else
            out << "%" << HEX[byte >> 4] << HEX[byte & 15]
          end
        end
        out
      end

      def unreserved?(byte)
        (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) ||
          (byte >= 48 && byte <= 57) || byte == 45 || byte == 95 || byte == 46 || byte == 126
      end
    end

    class Presigner
      def initialize(client:)
        @client = client
      end

      def presigned_url(_method, params)
        bucket     = params.key?(:bucket) ? params[:bucket] : params["bucket"]
        key        = params.key?(:key) ? params[:key] : params["key"]
        expires_in = params.key?(:expires_in) ? params[:expires_in] : params["expires_in"]
        @client.presigned_url(bucket, key, expires_in || 600)
      end
    end
  end
end

# --- Izen extras (the constant aliases live in compat.rb) ------------------

module Izen
  # AES-256-GCM encrypt/decrypt matching Izen::Encryptor in the CRuby gem:
  # PBKDF2-HMAC-SHA256 key derivation and a Base64/JSON payload.
  module Encryptor
    PBKDF2_ITERATIONS = 20_000

    module_function

    def encrypt(value)
      cipher     = OpenSSL::Cipher.new("aes-256-gcm")
      cipher.encrypt
      salt       = SecureRandom.bytes(16)
      cipher.key = derive_key(salt)
      iv         = SecureRandom.bytes(12)
      cipher.iv  = iv
      ciphertext = cipher.update(value.to_s) + cipher.final
      JSON.generate(
        "ct"   => Base64.strict_encode64(ciphertext),
        "iv"   => Base64.strict_encode64(iv),
        "tag"  => Base64.strict_encode64(cipher.auth_tag),
        "salt" => Base64.strict_encode64(salt)
      )
    end

    def decrypt(value)
      data              = JSON.parse(value)
      salt              = data["salt"] ? Base64.decode64(data["salt"]) : nil
      decipher          = OpenSSL::Cipher.new("aes-256-gcm")
      decipher.decrypt
      decipher.key      = derive_key(salt)
      decipher.iv       = Base64.decode64(data["iv"])
      decipher.auth_tag = Base64.decode64(data["tag"])
      decipher.update(Base64.decode64(data["ct"])) + decipher.final
    end

    def derive_key(salt)
      master = ENV["APP_ENCRYPTION_KEY"]
      raise "Set APP_ENCRYPTION_KEY in environment" if master.nil? || master.empty?

      if salt
        Crypto.pbkdf2_hmac_sha256(master, salt, PBKDF2_ITERATIONS, 32)
      else
        Crypto.sha256(master)
      end
    end
  end

  # Small HTTP client over MiniHttp, matching the CRuby Izen::HTTP surface
  # (same verbs, same keyword options). Returns a Response with `code`, `body`
  # and `headers` (`Response#[]` reads a header, as Net::HTTPResponse does).
  class HTTP
    METHODS              = %i[get head post put patch delete options trace].freeze
    DEFAULT_OPEN_TIMEOUT = 30
    DEFAULT_READ_TIMEOUT = 60

    class Response
      attr_accessor :code, :body, :headers

      def initialize(code, headers, body)
        @code    = code
        @headers = headers
        @body    = body
      end

      def [](name)
        @headers[name.to_s.downcase]
      end

      def to_s
        @body.to_s
      end
    end

    class << self
      def get(url, **options)
        request(:get, url, **options)
      end

      def head(url, **options)
        request(:head, url, **options)
      end

      def post(url, **options)
        request(:post, url, **options)
      end

      def put(url, **options)
        request(:put, url, **options)
      end

      def patch(url, **options)
        request(:patch, url, **options)
      end

      def delete(url, **options)
        request(:delete, url, **options)
      end

      def options(url, **options)
        request(:options, url, **options)
      end

      def trace(url, **options)
        request(:trace, url, **options)
      end

      def request(verb, url, **options)
        open_timeout = options.key?(:open_timeout) ? options[:open_timeout] : DEFAULT_OPEN_TIMEOUT
        read_timeout = options.key?(:read_timeout) ? options[:read_timeout] : DEFAULT_READ_TIMEOUT
        headers      = options.key?(:headers) ? options[:headers] : {}
        new(open_timeout: open_timeout, read_timeout: read_timeout, headers: headers)
          .request(verb, url, **options)
      end
    end

    def initialize(open_timeout: DEFAULT_OPEN_TIMEOUT, read_timeout: DEFAULT_READ_TIMEOUT, headers: nil)
      @open_timeout = open_timeout
      @read_timeout = read_timeout
      @headers      = headers || {}
    end

    def get(url, **options)
      request(:get, url, **options)
    end

    def head(url, **options)
      request(:head, url, **options)
    end

    def post(url, **options)
      request(:post, url, **options)
    end

    def put(url, **options)
      request(:put, url, **options)
    end

    def patch(url, **options)
      request(:patch, url, **options)
    end

    def delete(url, **options)
      request(:delete, url, **options)
    end

    def options(url, **options)
      request(:options, url, **options)
    end

    def trace(url, **options)
      request(:trace, url, **options)
    end

    def request(verb, url, headers: {}, params: nil, body: nil, json: nil, **_ignored)
      verb = verb.to_s.downcase
      raise ArgumentError, "unsupported HTTP method: #{verb}" unless METHODS.map { |name| name.to_s }.include?(verb)

      uri   = URI.parse(url.to_s)
      query = params && !params.empty? ? URI.encode_www_form(params) : uri.query

      merged                                              = {}
      @headers.each { |name, value| merged[name.to_s]     = value.to_s }
      headers.to_h.each { |name, value| merged[name.to_s] = value.to_s } if headers

      payload = nil
      if json
        merged["Content-Type"] = "application/json" unless merged.key?("Content-Type")
        merged["Accept"]       = "application/json" unless merged.key?("Accept")
        payload                = JSON.generate(json)
      elsif body
        payload = body.to_s
      end

      path   = uri.path.to_s
      path   = "/" if path.empty?
      path   = "#{path}?#{query}" if query && !query.empty?
      secure = uri.scheme == "https"
      port   = uri.port.nil? || uri.port.zero? ? (secure ? 443 : 80) : uri.port

      status, response_headers, response_body =
        MiniHttp.request(secure, uri.host.to_s, port, verb.upcase, path, merged, payload)
      Response.new(status.to_s, response_headers, response_body)
    end
  end
end

module Base
  # Background job base, lowered from `Izen::Base::Job`. A single worker thread
  # drains a shared queue (the native equivalent of the gem's worker), so
  # `perform_later`/`run` return immediately and the work happens off the
  # request. `JOBS_INLINE=1` keeps everything synchronous for tests.
  class Job
    @queue   = Queue.new
    @inline  = false
    @worker  = nil
    @mutex   = Mutex.new

    class << self
      attr_writer :inline

      def inline?
        @inline || ENV["JOBS_INLINE"] == "1"
      end

      def run(&block)
        enqueue(&block)
        nil
      end

      def perform_now(*args, **kwargs)
        new.perform(*args, **kwargs)
      end

      def perform_later(*args, **kwargs)
        enqueue { new.perform(*args, **kwargs) }
        nil
      end

      def enqueue(&block)
        if inline?
          block.call
          return nil
        end

        @queue << block
        ensure_worker
        nil
      end

      private

      def ensure_worker
        @mutex.synchronize do
          return if @worker && @worker.alive?

          @worker = Thread.new do
            loop do
              task = @queue.pop
              begin
                task.call
              rescue StandardError => e
                warn "[Job] #{e.class}: #{e.message}"
              end
            end
          end
        end
      end
    end

    def perform
      raise NotImplementedError, "#{self.class} must implement #perform"
    end
  end

  # Transactional mailer base, lowered from `Izen::Base::Mailer`. Builds a
  # Mail::Message; `deliver_now` sends it over the SMTP client above and
  # `deliver_later` enqueues it on the background worker.
  class Mailer
    class << self
      attr_writer :delivery_method

      def delivery_method
        @delivery_method || :smtp
      end

      def deliver_now(name, *args)
        new.deliver_now(name, *args)
      end

      def deliver_later(name, *args)
        new.deliver_later(name, *args)
      end

      def smtp_options
        {}
      end

      def smtp_address(value)
        value.to_s.empty? ? "localhost" : value
      end

      def smtp_port(value)
        value.to_s.empty? ? 587 : value.to_i
      end

      def decrypted(value)
        return value if value.nil? || value.empty?
        return value unless value.start_with?("{")

        begin
          Izen::Encryptor.decrypt(value)
        rescue StandardError
          value
        end
      end

      def admin_email
        ENV.fetch("ADMIN_EMAIL", "admin@example.com")
      end

      def default_from
        "noreply@example.com"
      end

      def app_url
        ENV.fetch("APP_URL", "http://localhost:3000")
      end
    end

    def deliver_now(name, *args)
      message = self.public_send(name, *args)
      return nil unless message

      deliver_message(message)
      message
    end

    def deliver_later(name, *args)
      message = self.public_send(name, *args)
      return nil unless message

      Base::Job.run { deliver_message(message) }
      message
    end

    private

    def deliver_message(message)
      if self.class.delivery_method == :test
        message.delivery_method :test
      else
        message.delivery_method :smtp, self.class.smtp_options
      end
      message.deliver
      message
    end

    def build(template, to:, replacements:, subject_replacements: nil, from: nil)
      subject_values = replacements.merge(subject_replacements || {})
      build_message(
        from:    from || self.class.default_from,
        to:      to,
        subject: substitute(template.subject.to_s, subject_values),
        body:    substitute(template.body.to_s, replacements)
      )
    end

    def build_message(from:, to:, subject:, body:)
      mail              = Mail.new
      mail.from         = from
      mail.to           = to
      mail.subject      = subject
      mail.content_type = "text/html; charset=UTF-8"
      mail.body         = body
      mail
    end

    def substitute(text, replacements)
      text.gsub(/\{\{(\w+)\}\}/) { replacements[Regexp.last_match(1)] || Regexp.last_match(0) }
    end

    def escaped(text)
      Rack::Utils.escape_html(text.to_s)
    end

    def money(amount)
      "Rp#{amount.to_i.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1.').reverse}"
    end
  end
end
