# frozen_string_literal: true

require_relative "../test_helper"

class DotenvTest < Minitest::Test
  def setup
    @path = File.join(Izen.root, ".env.test")
  end

  def teardown
    File.delete(@path) if File.exist?(@path)
    ENV.delete("IZEN_DOTENV_TEST")
  end

  def test_load_sets_missing_keys
    File.write(@path, "IZEN_DOTENV_TEST=value\n")

    Izen::Dotenv.load(@path)

    assert_equal "value", ENV["IZEN_DOTENV_TEST"]
  end

  def test_load_does_not_overwrite_existing_keys
    ENV["IZEN_DOTENV_TEST"] = "keep"
    File.write(@path, "IZEN_DOTENV_TEST=value\n")

    Izen::Dotenv.load(@path)

    assert_equal "keep", ENV["IZEN_DOTENV_TEST"]
  end

  def test_parse_handles_comments_quotes_and_blanks
    assert_nil Izen::Dotenv.parse("# comment")
    assert_nil Izen::Dotenv.parse("")
    assert_equal [ "K", "v" ], Izen::Dotenv.parse('K="v"')
  end
end
