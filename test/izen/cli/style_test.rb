# frozen_string_literal: true

require_relative "../../test_helper"
require "stringio"

class CliStyleTest < Minitest::Test
  def setup
    @no_color    = ENV.delete("NO_COLOR")
    @force_color = ENV.delete("FORCE_COLOR")
  end

  def teardown
    restore("NO_COLOR", @no_color)
    restore("FORCE_COLOR", @force_color)
  end

  def test_paint_is_plain_when_the_stream_is_not_a_tty
    output = StringIO.new
    result = Izen::Cli::Style.paint("created  app/x.rb", :green, stream: output)

    assert_equal "created  app/x.rb", result
  end

  def test_forced_color_wraps_text_in_ansi
    ENV["FORCE_COLOR"] = "1"

    assert_equal "\e[32mhi\e[0m", Izen::Cli::Style.green("hi")
  end

  def test_no_color_wins_over_force_color
    ENV["NO_COLOR"]    = "1"
    ENV["FORCE_COLOR"] = "1"

    refute Izen::Cli::Style.enabled?
  end

  def test_created_line_names_the_file_and_uses_color
    ENV["FORCE_COLOR"] = "1"

    line = Izen::Cli::Style.created("app/posts/model.rb")

    assert_includes line, "created"
    assert_includes line, "app/posts/model.rb"
    assert_includes line, "\e["
  end

  def test_pending_migrations_are_yellow
    ENV["FORCE_COLOR"] = "1"

    line = Izen::Cli::Style.migration_status("pending", "000002_create_posts.up.sql")

    assert_includes line, "pending"
    assert_includes line, "\e[33m"
  end

  def test_error_lines_are_bold_red
    ENV["FORCE_COLOR"] = "1"

    line = Izen::Cli::Style.error("boom")

    assert_includes line, "boom"
    assert_includes line, "\e[31;1m"
  end

  private

  def restore(key, value)
    value.nil? ? ENV.delete(key) : ENV[key] = value
  end
end
