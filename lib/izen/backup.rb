# frozen_string_literal: true

require "fileutils"
require "rubygems/package"
require "zlib"

require_relative "database"
require_relative "storage"

module Izen
  # Backs up the SQLite database and the uploads directory into a timestamped
  # folder under storage/backups.
  #
  #   Izen::Backup.run                       # storage/backups/<stamp>/
  #   Izen::Backup.run(dir: "/mnt/backups")  # a mounted volume
  #
  # The database is copied with `VACUUM INTO`, which produces a consistent,
  # defragmented snapshot even while the app is running (safe under WAL).
  # Uploads are written as a .tar.gz using Ruby's stdlib, so no `tar` binary is
  # required. A service whose files are not on this machine (S3) yields an empty
  # archive; back that store up through the provider.
  #
  # To restore: stop the app, copy the snapshot over the database file (delete
  # stale `-wal`/`-shm` first), extract the uploads archive over
  # `Izen::Storage.public_dir`, then start the app.
  module Backup
    class << self
      # Returns a hash with the written paths.
      def run(dir: default_dir, now: Time.now.utc)
        FileUtils.mkdir_p(dir)
        stamp = now.strftime("%Y%m%d-%H%M%S")

        {
          stamp:    stamp,
          database: backup_database(File.join(dir, "database-#{stamp}.sqlite3")),
          uploads:  backup_uploads(File.join(dir, "uploads-#{stamp}.tar.gz"))
        }
      end

      def default_dir
        File.join(Izen.root, "storage", "backups")
      end

      private

      def backup_database(path)
        File.delete(path) if File.exist?(path)
        Izen::Database.connection.execute("VACUUM INTO #{quote(path)}")
        path
      end

      def backup_uploads(path)
        File.open(path, "wb") do |file|
          Zlib::GzipWriter.wrap(file) do |gz|
            Gem::Package::TarWriter.new(gz) do |tar|
              each_upload do |entry|
                if entry[:directory]
                  tar.mkdir(entry[:key], entry[:mode])
                else
                  tar.add_file_simple(entry[:key], entry[:mode], entry[:size]) do |io|
                    entry[:write].call(io)
                  end
                end
              end
            end
          end
        end
        path
      end

      # Yields one entry per upload. A service backed by a directory on this
      # machine is streamed from disk; a remote service (S3/R2) is enumerated
      # through Izen::Storage.list and read object by object.
      def each_upload(&block)
        dir = Izen::Storage.public_dir
        if dir && Dir.exist?(dir)
          each_local_upload(dir, &block)
        else
          each_remote_upload(&block)
        end
      end

      def each_local_upload(dir)
        Dir.glob(File.join(dir, "**", "*")).sort.each do |path|
          key = path.delete_prefix("#{dir}/")
          if File.directory?(path)
            yield({ key: key, directory: true, mode: File.stat(path).mode })
          else
            yield({
              key:   key,
              mode:  File.stat(path).mode,
              size:  File.size(path),
              write: ->(io) { File.open(path, "rb") { |source| IO.copy_stream(source, io) } }
            })
          end
        end
      end

      def each_remote_upload
        Izen::Storage.list.each do |object|
          bytes = Izen::Storage.read(object[:key])
          yield({
            key:   object[:key],
            mode:  0o644,
            size:  bytes.bytesize,
            write: ->(io) { io.write(bytes) }
          })
        end
      end

      # SQLite's VACUUM INTO takes a literal path, not a bind parameter.
      def quote(path)
        "'#{path.to_s.gsub("'", "''")}'"
      end
    end
  end
end
