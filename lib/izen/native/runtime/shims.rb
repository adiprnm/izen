# frozen_string_literal: true

require "stringio"
require "uri"
require "socket"
require "openssl"
require "base64"

# Stand-ins for the third-party libraries the source app uses, written in the
# subset Spinel can compile. They implement the surface the app calls, so the
# copied domain code type-checks and runs; features that need a real C
# extension or network stack degrade to no-ops instead of failing the build.

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

module Sanitize
  class Config
    RELAXED = { elements: [], attributes: {}, protocols: {} }

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

  # The native build trust the admin-authored rich text (it is gated by
  # require_admin! on save); there is no HTML parser to sanitize with, so the
  # body passes through unchanged.
  def fragment(html, _config = nil)
    html.to_s
  end

  def document(html, _config = nil)
    html.to_s
  end

  def clean(html, _config = nil)
    html.to_s
  end
end

# --- Nokogiri (a tiny stand-in) -------------------------------------------

# The native build has no HTML parser. `HTML5.fragment` keeps the markup and
# `css` answers an empty (but typed) node list, so the app's token pass falls
# through to the `{{token}}` substitution that follows it.
module Nokogiri
  module HTML5
    def self.fragment(html)
      Fragment.new(html)
    end
  end

  class Node
    def initialize
      @attrs = {}
      @text  = ""
    end

    def [](key)
      @attrs[key.to_s]
    end

    def []=(key, value)
      @attrs[key.to_s] = value
    end

    def remove_attribute(key)
      @attrs.delete(key.to_s)
    end

    def remove
      nil
    end

    def content
      @text
    end

    def content=(value)
      @text = value
    end

    def text
      @text
    end

    def inner_html=(value)
      @text = value
    end

    def swap(html)
      @text = html
    end

    def to_html
      @text.to_s
    end
  end

  class Fragment
    def initialize(html)
      @html  = html.to_s
      # A typed (non-empty) node list so the caller's block compiles; the
      # stand-in node is detached, so the markup passes through unchanged and
      # the `{{token}}` substitution that follows does the real work.
      @nodes = [ Node.new ]
    end

    def css(_selector)
      @nodes
    end

    def to_html
      @html
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

module Rufus
  class Scheduler
    def cron(_expression, _options = nil, &block)
      block&.call
      nil
    end

    def every(_interval, _options = nil, &block)
      block&.call
      nil
    end

    def in(_interval, _options = nil, &block)
      block&.call
      nil
    end

    def shutdown
      nil
    end
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
    end

    class Object
      attr_accessor :content_type, :content_length, :body
    end

    class Client
      def initialize(_options = nil)
        @store = {}
      end

      def put_object(bucket:, key:, content_type:, body:)
        @store["#{bucket}/#{key}"] = body
        true
      end

      def delete_object(bucket:, key:)
        @store.delete("#{bucket}/#{key}")
        true
      end

      def get_object(bucket:, key:)
        object                = Object.new
        object.content_type   = "application/octet-stream"
        object.content_length = 0
        object.body           = StringIO.new("")
        object
      end
    end

    class Presigner
      def initialize(client:)
        @client = client
      end

      def presigned_url(_method, _params)
        ""
      end
    end
  end
end

# --- Izen extras (the constant aliases live in compat.rb) ------------------

module Izen
  # AES-256-GCM encryptor stand-in: the native build has no key management, so
  # values round-trip as-is.
  module Encryptor
    module_function

    def encrypt(value)
      value.to_s
    end

    def decrypt(value)
      value.to_s
    end
  end

  # Minimal HTTP client surface. The native build does not carry net/http, so a
  # request answers an empty 200; callers handle the provider response.
  class HTTP
    METHODS = %i[get post put patch delete head options].freeze

    class Response
      attr_accessor :code, :body, :headers

      def initialize
        @code    = 200
        @body    = ""
        @headers = {}
      end
    end

    def initialize(open_timeout: nil, read_timeout: nil, headers: nil, **_options)
      @headers = headers || {}
    end

    def request(_method, _url, _options = {})
      Response.new
    end

    def get(_url, options = {})
      Response.new
    end

    def post(_url, options = {})
      Response.new
    end

    def put(_url, options = {})
      Response.new
    end

    def patch(_url, options = {})
      Response.new
    end

    def delete(_url, options = {})
      Response.new
    end

    class << self
      def get(url, options = {})
        new.get(url, options)
      end

      def post(url, options = {})
        new.post(url, options)
      end
    end
  end
end

module Base
  # Background job base, lowered from `Izen::Base::Job`. Everything runs
  # inline; the native build has no work queue.
  class Job
    class << self
      def inline?
        true
      end

      def run(&block)
        block.call
        nil
      end

      def perform_now(*args, **kwargs)
        new.perform(*args, **kwargs)
      end

      def perform_later(*args, **kwargs)
        new.perform(*args, **kwargs)
      end

      def enqueue(&block)
        block.call
        nil
      end
    end

    def perform
      raise NotImplementedError, "#{self.class} must implement #perform"
    end
  end

  # Transactional mailer base, lowered from `Izen::Base::Mailer`. Builds a
  # Mail::Message; delivery is recorded by the Mail stand-in.
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

      deliver_message(message)
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
