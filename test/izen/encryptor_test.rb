# frozen_string_literal: true

require_relative "../test_helper"

class EncryptorTest < Minitest::Test
  def test_roundtrip
    ciphertext = Izen::Encryptor.encrypt("super-secret")

    refute_includes ciphertext, "super-secret"
    assert_equal "super-secret", Izen::Encryptor.decrypt(ciphertext)
  end

  def test_each_encryption_uses_a_fresh_salt
    refute_equal Izen::Encryptor.encrypt("x"), Izen::Encryptor.encrypt("x")
  end
end
