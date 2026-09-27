# frozen_string_literal: true

require "mail"

module Izen
  module Base
    # Base class for transactional mailers.
    #
    # A subclass defines methods that build and return a `Mail::Message`. The
    # caller then chooses when to send it:
    #
    #   Orders::Mailer.deliver_now(:download, order.id)
    #   Orders::Mailer.deliver_later(:download, order.id)
    #
    # The base stays free of app concerns: SMTP options, the admin address and the
    # default From come from overridable class methods (see AppMailer).
    class Mailer
      class << self
        # `:smtp` in production; tests set it to `:test` so nothing hits the network.
        attr_writer :delivery_method

        def delivery_method
          return @delivery_method if defined?(@delivery_method) && @delivery_method

          superclass.respond_to?(:delivery_method) ? superclass.delivery_method : :smtp
        end

        def deliver_now(name, *args)
          new.deliver_now(name, *args)
        end

        def deliver_later(name, *args)
          new.deliver_later(name, *args)
        end

        # SMTP options; subclasses override with real credentials.
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

          Encryptor.decrypt(value) rescue value
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

      # Builds the message for `name` and sends it immediately.
      def deliver_now(name, *args)
        message = public_send(name, *args)
        return unless message

        deliver_message(message)
        message
      end

      # Builds the message for `name` and sends it on the background worker.
      def deliver_later(name, *args)
        message = public_send(name, *args)
        return unless message

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

      # Builds a Mail::Message from a template (anything responding to
      # #subject / #body) with {{placeholder}} substitution.
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
        text.gsub(/\{\{(\w+)\}\}/) { replacements[$1] || "{{#{$1}}}" }
      end

      def escaped(text)
        Rack::Utils.escape_html(text.to_s)
      end

      def money(amount)
        "Rp#{amount.to_i.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1.').reverse}"
      end
    end
  end
end
