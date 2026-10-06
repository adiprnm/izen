# frozen_string_literal: true

require_relative "../test_helper"
require "rack/test"
require "stringio"

class StorageTest < Minitest::Test
  def setup
    @root     = Izen.root
    @uploads  = File.join(@root, "storage", "uploads")
    FileUtils.mkdir_p(@uploads)
    Izen::Storage.reset!
  end

  def teardown
    FileUtils.rm_rf(@uploads)
    FileUtils.rm_f(File.join(@root, "config", "storage.yml"))
    Izen::Storage.reset!
  end

  def upload(body = "hello", filename: "avatar.png")
    { filename: filename, type: "image/png", tempfile: StringIO.new(body) }
  end

  def test_defaults_to_the_local_service_under_storage_uploads
    config = Izen::Storage.config

    assert_equal "local", config["service"]
    assert_equal Izen::Storage::DEFAULT_PATH, config["path"]
    assert_equal Izen::Storage::DEFAULT_URL, config["url"]
    assert_equal File.join(@root, "storage", "uploads"), Izen::Storage.public_dir
    assert_equal "/uploads", Izen::Storage.public_url
  end

  def test_stores_a_rack_upload_and_returns_a_key
    key = Izen::Storage.store(upload("binary-bytes"))

    assert_match(%r{\A\d{4}/\d{2}/[0-9a-f]{32}\.png\z}, key)
    assert Izen::Storage.exist?(key)
    assert_equal "binary-bytes", Izen::Storage.read(key)
    assert_equal "/uploads/#{key}", Izen::Storage.url(key)
    assert_equal "binary-bytes", File.binread(File.join(@uploads, key))
  end

  def test_uses_the_given_key
    key = Izen::Storage.store(upload, key: "avatars/me.png")

    assert_equal "avatars/me.png", key
    assert_equal "/uploads/avatars/me.png", Izen::Storage.url(key)
    assert File.file?(File.join(@uploads, "avatars", "me.png"))
  end

  def test_accepts_a_file_path
    source = File.join(@root, "source.gif")
    File.binwrite(source, "gif-bytes")

    key = Izen::Storage.store(source)

    assert_match(/\.gif\z/, key)
    assert_equal "gif-bytes", Izen::Storage.read(key)
  ensure
    FileUtils.rm_f(source)
  end

  def test_delete_removes_the_file
    key = Izen::Storage.store(upload)

    assert Izen::Storage.delete(key)
    refute Izen::Storage.exist?(key)
    refute Izen::Storage.delete(key)
  end

  def test_local_list_enumerates_stored_keys_with_sizes
    Izen::Storage.store(upload("a"), key: "one.png")
    Izen::Storage.store(upload("bb"), key: "nested/two.png")

    entries = Izen::Storage.list.map { |entry| [ entry[:key], entry[:size] ] }.sort

    assert_equal [ [ "nested/two.png", 2 ], [ "one.png", 1 ] ], entries
  end

  def test_rejects_path_traversal
    assert_raises(Izen::Storage::Error) do
      Izen::Storage.store(upload, key: "../../etc/passwd")
    end
    assert_raises(Izen::Storage::Error) { Izen::Storage.read("../secret") }
  end

  def test_reads_the_service_from_config_storage_yml
    write_storage_config(<<~YAML)
      test:
        service: local
        path: storage/custom
        url: /files
    YAML
    Izen::Storage.reset!

    assert_equal File.join(@root, "storage", "custom"), Izen::Storage.public_dir
    assert_equal "/files", Izen::Storage.public_url

    key = Izen::Storage.store(upload)
    assert_equal "/files/#{key}", Izen::Storage.url(key)
    assert File.file?(File.join(@root, "storage", "custom", key))
  ensure
    FileUtils.rm_rf(File.join(@root, "storage", "custom"))
  end

  def test_reads_erb_env_values_from_config
    ENV["TEST_STORAGE_URL"] = "/assets"
    write_storage_config(<<~YAML)
      test:
        service: local
        path: storage/uploads
        url: "<%= ENV["TEST_STORAGE_URL"] %>"
    YAML
    Izen::Storage.reset!

    assert_equal "/assets", Izen::Storage.public_url
    assert_equal "/assets/avatar.png", Izen::Storage.url("avatar.png")
  ensure
    ENV.delete("TEST_STORAGE_URL")
  end

  def test_unknown_service_raises
    write_storage_config(<<~YAML)
      test:
        service: gcs
        bucket: nope
    YAML
    Izen::Storage.reset!

    assert_raises(Izen::Storage::MissingService) { Izen::Storage.service }
  end

  def test_builds_the_s3_service_from_config
    write_storage_config(<<~YAML)
      test:
        service: s3
        bucket: my-bucket
        endpoint: https://example.r2.cloudflarestorage.com
    YAML
    Izen::Storage.reset!

    service = Izen::Storage.service
    assert_instance_of Izen::Storage::S3, service
    assert_equal "my-bucket", service.bucket
  end

  # A stand-in for Aws::S3::Client so the service can be tested without the
  # gem, the network or credentials.
  class FakeS3Client
    NotFound = Class.new(StandardError)

    attr_reader :objects
    attr_accessor :page_size

    def initialize
      @objects   = {}
      @page_size = 100
    end

    def put_object(bucket:, key:, body:, content_type:)
      body.rewind if body.respond_to?(:rewind)
      @objects[[ bucket, key ]] = { body: body.read, content_type: content_type }
      true
    end

    def get_object(bucket:, key:)
      data = @objects[[ bucket, key ]] or raise NotFound, "NoSuchKey"
      Struct.new(:body).new(StringIO.new(data[:body]))
    end

    def head_object(bucket:, key:)
      @objects[[ bucket, key ]] or raise NotFound, "NotFound"
      true
    end

    def delete_object(bucket:, key:)
      @objects.delete([ bucket, key ])
      true
    end

    def list_objects_v2(bucket:, prefix: nil, continuation_token: nil)
      keys = @objects.keys.select { |b, _k| b == bucket }.map { |_b, key| key }
      keys = keys.select { |key| key.start_with?(prefix) } if prefix
      keys = keys.sort

      offset      = continuation_token.to_i
      page        = keys[offset, @page_size] || []
      next_offset = offset + page.size
      truncated   = next_offset < keys.size
      contents    = page.map { |key| Struct.new(:key, :size).new(key, @objects[[ bucket, key ]][:body].bytesize) }

      Struct.new(:contents, :is_truncated, :next_continuation_token)
            .new(contents, truncated, truncated ? next_offset.to_s : nil)
    end

    def presigned_url(bucket, key, expires_in)
      "https://signed.example/#{bucket}/#{key}?expires=#{expires_in}"
    end
  end

  def s3_service(settings = {})
    client  = FakeS3Client.new
    service = Izen::Storage::S3.new(
      { "service" => "s3", "bucket" => "bucket" }.merge(settings).merge("client" => client),
      root: @root
    )
    [ service, client ]
  end

  def test_s3_stores_reads_and_deletes
    service, client = s3_service("prefix" => "media")

    key = service.store(upload("s3-bytes"), key: "avatar.png")

    assert_equal "avatar.png", key
    assert_equal "s3-bytes", client.objects[[ "bucket", "media/avatar.png" ]][:body]
    assert_equal "image/png", client.objects[[ "bucket", "media/avatar.png" ]][:content_type]
    assert_equal "s3-bytes", service.read(key)
    assert service.exist?(key)
    assert service.delete(key)
    refute service.exist?(key)
  end

  def test_s3_generates_a_key_when_none_is_given
    service, client = s3_service

    key = service.store(upload)

    assert_match(%r{\A\d{4}/\d{2}/[0-9a-f]{32}\.png\z}, key)
    assert client.objects.key?([ "bucket", key ])
  end

  def test_s3_url_uses_public_url_when_configured
    service, = s3_service("public_url" => "https://cdn.example.com/")

    assert_equal "https://cdn.example.com/avatar.png", service.url("avatar.png")
  end

  def test_s3_url_presigns_when_private
    service, = s3_service

    assert_equal(
      "https://signed.example/bucket/avatar.png?expires=600",
      service.url("avatar.png", expires_in: 600)
    )
  end

  def test_s3_requires_a_bucket
    assert_raises(Izen::Storage::Error) do
      Izen::Storage::S3.new({ "service" => "s3" }, root: @root)
    end
  end

  def test_s3_lists_objects_and_strips_the_prefix
    service, = s3_service("prefix" => "media")
    service.store(upload("a"), key: "one.png")
    service.store(upload("bb"), key: "two.png")

    entries = service.list.map { |entry| [ entry[:key], entry[:size] ] }.sort

    assert_equal [ [ "one.png", 1 ], [ "two.png", 2 ] ], entries
  end

  def test_s3_list_filters_by_prefix
    service, = s3_service("prefix" => "media")
    service.store(upload("a"), key: "one.png")
    service.store(upload("bb"), key: "two.png")

    assert_equal [ "two.png" ], service.list(prefix: "two").map { |entry| entry[:key] }
  end

  def test_s3_list_follows_pagination
    service, client  = s3_service
    client.page_size = 2
    service.store(upload("a"), key: "a.png")
    service.store(upload("b"), key: "b.png")
    service.store(upload("c"), key: "c.png")

    assert_equal %w[a.png b.png c.png], service.list.map { |entry| entry[:key] }
  end

  private

  def write_storage_config(content)
    path = File.join(@root, "config", "storage.yml")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end
end

# The configured local directory is mounted at /uploads by Izen::Application.
class StorageServingTest < Minitest::Test
  class App < Izen::Application
    route do |r|
      r.root { "home" }
    end
  end

  include Rack::Test::Methods

  def app
    App
  end

  def setup
    @uploads = File.join(Izen.root, "storage", "uploads")
    FileUtils.mkdir_p(@uploads)
    File.binwrite(File.join(@uploads, "hello.txt"), "served")
  end

  def teardown
    FileUtils.rm_rf(@uploads)
  end

  def test_serves_uploaded_files_under_uploads
    get "/uploads/hello.txt"

    assert last_response.ok?
    assert_equal "served", last_response.body
  end

  def test_does_not_shadow_the_application
    get "/"

    assert last_response.ok?
    assert_equal "home", last_response.body
  end
end
