# frozen_string_literal: true

require_relative "../test_helper"
require "tempfile"

class StorageValidationTest < Minitest::Test
  PNG  = "\x89PNG\r\n\x1a\n".b
  JPEG = "\xFF\xD8\xFF\xE0".b
  WEBP = "RIFF\x00\x00\x00\x00WEBP".b

  def upload(name:, type:, bytes:)
    file         = Tempfile.new([ "upload", File.extname(name) ])
    file.binmode
    file.write(bytes)
    file.rewind
    @tempfiles ||= []
    @tempfiles << file
    Rack::Test::UploadedFile.new(file.path, type)
  end

  def teardown
    @tempfiles&.each(&:close!)
  end

  def test_accepts_png_jpeg_and_webp
    assert Izen::Storage.image?(upload(name: "a.png", type: "image/png", bytes: PNG))
    assert Izen::Storage.image?(upload(name: "a.jpg", type: "image/jpeg", bytes: JPEG))
    assert Izen::Storage.image?(upload(name: "a.webp", type: "image/webp", bytes: WEBP))
  end

  def test_rejects_unknown_extension
    error = Izen::Storage.image_error(upload(name: "a.gif", type: "image/gif", bytes: "GIF89a".b))

    refute_nil error
    assert_includes error, "JPG"
  end

  def test_rejects_non_image_content_with_image_extension
    error = Izen::Storage.image_error(upload(name: "evil.png", type: "image/png", bytes: "<?php echo 1; ?>"))

    assert_includes error, "gambar"
  end

  def test_rejects_oversized_files
    big = PNG + ("x" * (Izen::Storage::Validation::MAX_IMAGE_BYTES + 1))

    assert_includes Izen::Storage.image_error(upload(name: "big.png", type: "image/png", bytes: big)), "5 MB"
  end
end
