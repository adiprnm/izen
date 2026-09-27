# frozen_string_literal: true

require_relative "../../test_helper"

class MailerTest < Minitest::Test
  class WelcomeMailer < Izen::Base::Mailer
    def welcome(to)
      build_message(from: self.class.default_from, to: to, subject: "Hi", body: "Hello")
    end
  end

  def setup
    Izen::Base::Mailer.delivery_method = :test
    Mail::TestMailer.deliveries.clear
  end

  def test_deliver_now_sends_the_message
    WelcomeMailer.deliver_now(:welcome, "a@example.com")

    assert_equal 1, Mail::TestMailer.deliveries.size
    assert_equal [ "a@example.com" ], Mail::TestMailer.deliveries.first.to
  end

  def test_default_config
    assert_equal({}, Izen::Base::Mailer.smtp_options)
    assert_equal "noreply@example.com", Izen::Base::Mailer.default_from
    assert_equal 587, Izen::Base::Mailer.smtp_port(nil)
    assert_equal "localhost", Izen::Base::Mailer.smtp_address(nil)
  end

  def test_build_substitutes_placeholders
    message = WelcomeMailer.new.send(
      :build,
      Struct.new(:subject, :body).new("Hi {{name}}", "Hello {{name}}"),
      to:           "a@example.com",
      replacements: { "name" => "Adi" }
    )

    assert_equal "Hi Adi", message.subject
  end
end
