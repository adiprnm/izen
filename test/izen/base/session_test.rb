# frozen_string_literal: true

require_relative "../../test_helper"

class SessionTest < Minitest::Test
  def test_encode_decode_roundtrip
    encoded = Izen::Base::Session.encode("cart" => { "1" => 2 })

    assert_equal({ "cart" => { "1" => 2 } }, Izen::Base::Session.decode(encoded))
  end

  def test_tampered_payload_is_rejected
    encoded  = Izen::Base::Session.encode("user" => 1)
    tampered = encoded.sub(/\A[a-z0-9]/i) { |char| char == "a" ? "b" : "a" }

    assert_equal({}, Izen::Base::Session.decode(tampered))
  end

  def test_garbage_returns_empty_hash
    assert_equal({}, Izen::Base::Session.decode("not-a-cookie"))
  end
end
