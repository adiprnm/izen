# frozen_string_literal: true

require_relative "../test_helper"

class SanitizerTest < Minitest::Test
  def sanitize(html)
    Izen::Sanitizer.sanitize(html)
  end

  def test_keeps_allowed_formatting
    html = "<p><strong>Bold</strong> and <em>italic</em> and <u>under</u></p>"

    assert_equal html, sanitize(html)
  end

  def test_drops_script_blocks_and_their_content
    result = sanitize("hello<script>alert('xss')</script>world")

    assert_equal "helloworld", result
    refute_includes result, "alert"
  end

  def test_strips_event_handler_attributes
    assert_equal "<p>hi</p>", sanitize(%(<p onclick="alert(1)">hi</p>))
  end

  def test_blocks_javascript_urls
    assert_equal "<a>x</a>", sanitize(%(<a href="javascript:alert(1)">x</a>))
  end

  def test_blocks_obfuscated_javascript_urls
    refute_includes sanitize(%(<a href="java\tscript:alert(1)">x</a>)), "script:"
  end

  def test_keeps_safe_links
    html = %(<a href="https://example.com" title="ok">x</a>)

    assert_equal html, sanitize(html)
  end

  def test_drops_disallowed_tags
    assert_equal "", sanitize("<iframe>hi</iframe>")
    assert_equal "hi", sanitize("<custom-tag>hi</custom-tag>")
  end

  def test_handles_nil
    assert_equal "", sanitize(nil)
  end
end
