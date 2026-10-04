# frozen_string_literal: true

require_relative "secure_random"

# File storage for the lowered runtime. Mirrors the surface of Izen::Storage in
# the CRuby gem (store/read/delete/exist?/url) and dispatches on the service
# named in the app's storage config.
#
# YAML is unavailable under Spinel, so config/storage.yml is baked into
# generated/storage_config.rb at generation time (see StorageConfig). Secret
# values can always be overridden from the environment, which is where they
# should live: S3_BUCKET, S3_REGION, S3_ENDPOINT, S3_ACCESS_KEY_ID,
# S3_SECRET_ACCESS_KEY, S3_PREFIX, S3_PUBLIC_URL. STORAGE_SERVICE overrides the
# service name itself.
module Storage
  class Error < StandardError; end

  DEFAULT_PATH = "storage/uploads"
  DEFAULT_URL  = "/uploads"
  EXTENSION    = /\A\.[a-z0-9]{1,8}\z/

  module_function

  # --- dispatch --------------------------------------------------------

  def store(upload, key: nil)
    backend.store(upload, key: key)
  end

  def read(key)
    backend.read(key)
  end

  def delete(key)
    backend.delete(key)
  end

  def exist?(key)
    backend.exist?(key)
  end

  def url(key, **options)
    backend.url(key, **options)
  end

  def public_dir
    backend.public_dir
  end

  def public_url
    backend.public_url
  end

  def backend
    s3? ? S3 : Local
  end

  def s3?
    name = ENV["STORAGE_SERVICE"] || settings["service"] || "local"
    name == "s3" || name == "s3_compatible"
  end

  def env
    ENV["APP_ENV"] || "development"
  end

  def settings
    StorageConfig::SETTINGS[env] || StorageConfig::DEFAULT
  end

  # --- shared upload / key helpers -------------------------------------

  def filename_for(upload)
    name =
      if upload.is_a?(Hash)
        upload[:filename] || upload["filename"]
      elsif upload.respond_to?(:original_filename)
        upload.original_filename
      elsif upload.is_a?(String)
        upload
      else
        ""
      end
    clean_filename(name)
  end

  def content_for(upload)
    if upload.is_a?(Hash)
      io = upload[:tempfile] || upload["tempfile"]
      raise Error, "upload hash is missing :tempfile" if io.nil?

      read_io(io)
    elsif upload.respond_to?(:tempfile)
      read_io(upload.tempfile)
    elsif upload.respond_to?(:read)
      read_io(upload)
    elsif upload.is_a?(String)
      raise Error, "no such file: #{upload}" unless File.file?(upload)

      File.binread(upload)
    else
      raise Error, "cannot read an upload from #{upload.class}"
    end
  end

  def content_type_for(upload)
    type =
      if upload.is_a?(Hash)
        upload[:type] || upload["type"]
      elsif upload.respond_to?(:content_type)
        upload.content_type
      end
    type.nil? || type.to_s.empty? ? "application/octet-stream" : type.to_s
  end

  def read_io(io)
    io.rewind if io.respond_to?(:rewind)
    io.read
  end

  # Date-sharded, random key preserving a safe extension: 2026/10/9f…c1.png.
  def generate_key(filename)
    extension = File.extname(filename.to_s).downcase
    extension = "" unless extension.match?(EXTENSION)
    "#{Time.now.strftime("%Y/%m")}/#{SecureRandom.hex(16)}#{extension}"
  end

  def normalize_key(key)
    key   = key.to_s.tr("\\", "/").sub(/\A\/+/, "")
    parts = key.split("/")
    raise Error, "invalid storage key" if key.empty?

    parts.each do |part|
      raise Error, "invalid storage key #{key}" if part.empty? || part == "." || part == ".."
    end
    key
  end

  def clean_filename(name)
    name.to_s.tr("\\", "/").split("/").last.to_s
  end

  # `Dir.mkdir` is one level only (and there is no FileUtils in the runtime),
  # so create each segment of a sharded key in turn.
  def mkdir_p(directory)
    parts   = directory.split("/")
    current = ""
    parts.each do |part|
      next if part.empty?

      current = current.empty? ? part : "#{current}/#{part}"
      Dir.mkdir(current) unless File.directory?(current)
    end
    nil
  end

  # --- local backend ---------------------------------------------------

  module Local
    module_function

    def store(upload, key: nil)
      key ||= Storage.generate_key(Storage.filename_for(upload))
      key   = Storage.normalize_key(key)
      path  = absolute(key)

      Storage.mkdir_p(File.dirname(path))
      File.open(path, "wb") { |file| file.write(Storage.content_for(upload)) }
      key
    end

    def read(key)
      File.binread(absolute(key))
    end

    def delete(key)
      path = absolute(key)
      return false unless File.file?(path)

      File.delete(path)
      true
    end

    def exist?(key)
      File.file?(absolute(key))
    end

    def url(key, **_options)
      "#{url_base}/#{Storage.normalize_key(key)}"
    end

    def public_dir
      path
    end

    def public_url
      url_base.start_with?("/") ? url_base : nil
    end

    def path
      value = setting("path")
      value.nil? || value.to_s.empty? ? Storage::DEFAULT_PATH : value.to_s
    end

    def url_base
      value = setting("url")
      value = value.nil? || value.to_s.empty? ? Storage::DEFAULT_URL : value.to_s
      value.sub(/\/+\z/, "")
    end

    def absolute(key)
      "#{path}/#{Storage.normalize_key(key)}"
    end

    def setting(key)
      values = Storage.settings
      values[key] || values[key.to_sym]
    end
  end

  # --- s3-compatible backend -------------------------------------------

  module S3
    module_function

    def store(upload, key: nil)
      key ||= Storage.generate_key(Storage.filename_for(upload))
      key   = Storage.normalize_key(key)

      client.put_object(
        bucket:       bucket,
        key:          object_key(key),
        content_type: Storage.content_type_for(upload),
        body:         Storage.content_for(upload)
      )
      key
    end

    def read(key)
      client.get_object(bucket: bucket, key: object_key(key)).body.read
    end

    def delete(key)
      client.delete_object(bucket: bucket, key: object_key(key))
      true
    end

    def exist?(key)
      client.get_object(bucket: bucket, key: object_key(key))
      true
    rescue Aws::S3::Errors::NoSuchKey
      false
    end

    def url(key, expires_in: nil)
      object = object_key(key)
      base   = option("public_url", "S3_PUBLIC_URL")
      return "#{base.sub(/\/+\z/, "")}/#{object}" if base

      client.presigned_url(bucket, object, (expires_in || expires).to_i)
    end

    def public_dir
      nil
    end

    def public_url
      nil
    end

    def bucket
      value = option("bucket", "S3_BUCKET")
      raise Storage::Error, "storage service s3 requires a bucket (config/storage.yml or S3_BUCKET)" if value.nil?

      value
    end

    def client
      Aws::S3::Client.new(client_options)
    end

    def client_options
      {
        endpoint:          option("endpoint", "S3_ENDPOINT").to_s,
        region:            (option("region", "S3_REGION") || "auto").to_s,
        access_key_id:     option("access_key_id", "S3_ACCESS_KEY_ID").to_s,
        secret_access_key: option("secret_access_key", "S3_SECRET_ACCESS_KEY").to_s
      }
    end

    def object_key(key)
      key      = Storage.normalize_key(key)
      existing = prefix
      existing.empty? ? key : "#{existing}/#{key}"
    end

    def prefix
      (option("prefix", "S3_PREFIX") || "").sub(/\A\/+/, "").sub(/\/+\z/, "")
    end

    def expires
      (option("expires_in", "S3_URL_EXPIRES_IN") || 3600).to_i
    end

    def option(key, env_key)
      values = Storage.settings
      value  = values[key] || values[key.to_sym]
      value  = ENV[env_key] if value.nil? || value.to_s.empty?
      value.nil? || value.to_s.empty? ? nil : value.to_s
    end
  end
end
