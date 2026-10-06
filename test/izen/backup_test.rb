# frozen_string_literal: true

require_relative "../test_helper"
require "tmpdir"
require "zlib"
require "minitest/mock"

class BackupTest < Minitest::Test
  def setup
    TestSupport.db
    @dir = Dir.mktmpdir("izen-backup")
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir && Dir.exist?(@dir)
  end

  def test_backs_up_the_database_and_uploads
    result = Izen::Backup.run(dir: @dir)

    assert File.file?(result[:database]), "database snapshot should exist"
    assert_operator File.size(result[:database]), :>, 0
    assert File.file?(result[:uploads]), "uploads archive should exist"

    check = SQLite3::Database.new(result[:database])
    assert_equal 1, check.get_first_value("SELECT 1")
    assert check.table_info("widgets").any?
  ensure
    check&.close
  end

  def test_gzip_archive_is_valid
    result = Izen::Backup.run(dir: @dir)

    Zlib::GzipReader.open(result[:uploads]) { |gz| gz.read(1) }
    assert true
  end

  def test_default_dir_is_under_storage
    assert_equal File.join(Izen.root, "storage", "backups"), Izen::Backup.default_dir
  end

  def test_backs_up_a_remote_service_by_listing
    Izen::Storage.stub(:public_dir, nil) do
      Izen::Storage.stub(:list, [ { key: "2026/10/a.png", size: 4 } ]) do
        Izen::Storage.stub(:read, "png!") do
          result = Izen::Backup.run(dir: @dir)

          assert_equal "png!", tar_entries(result[:uploads])["2026/10/a.png"]
        end
      end
    end
  end

  private

  def tar_entries(path)
    entries = {}
    Zlib::GzipReader.open(path) do |gz|
      Gem::Package::TarReader.new(gz) do |tar|
        tar.each { |entry| entries[entry.full_name] = entry.read if entry.file? }
      end
    end
    entries
  end
end
