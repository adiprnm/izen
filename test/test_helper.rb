# frozen_string_literal: true

ENV["APP_ENV"]            ||= "test"
ENV["SESSION_SECRET"]     ||= "test-secret-" * 6
ENV["APP_ENCRYPTION_KEY"] ||= "test-encryption-key"
# Run background jobs synchronously so tests stay deterministic.
ENV["JOBS_INLINE"]          = "1"

require "minitest/autorun"
require "fileutils"
require "tmpdir"

require "izen"

# Every test runs against a throwaway app root so Database/Session/Dotenv
# resolve their paths under tmp/ instead of the gem checkout.
module TestSupport
  def self.root
    @root ||= begin
      dir = Dir.mktmpdir("izen-test")
      FileUtils.mkdir_p(File.join(dir, "config"))
      File.write(
        File.join(dir, "config", "database.yaml"),
        { "test" => { "path" => "storage/test.db" } }.to_yaml
      )
      Minitest.after_run { FileUtils.remove_entry(dir) }
      dir
    end
  end

  # Opens the test database and creates the shared `widgets` table used by the
  # repository/CLI tests.
  def self.db
    @db ||= Izen::Database.connection.tap do |connection|
      connection.execute(<<~SQL)
        CREATE TABLE IF NOT EXISTS widgets (
          id         INTEGER PRIMARY KEY AUTOINCREMENT,
          name       TEXT    NOT NULL,
          price      INTEGER NOT NULL DEFAULT 0,
          created_at TEXT
        );
      SQL
    end
  end

  # `Repository#model_class` resolves `<Namespace>::Repository` to
  # `<Namespace>::Model`, so the test fixtures follow that convention.
  module Widgets
    class Model < Izen::Base::Model
      attribute :id,         Integer, required: false
      attribute :name,       String
      attribute :price,      Integer, required: false
      attribute :created_at, Time,    required: false
    end

    class Repository < Izen::Base::Repository
      def all
        to_models(query("SELECT * FROM widgets ORDER BY id"))
      end

      def find(id)
        to_model(find_one("SELECT * FROM widgets WHERE id = ?", [ id ]))
      end

      def create(widget)
        db.execute(
          "INSERT INTO widgets (name, price, created_at) VALUES (?, ?, ?)",
          [ widget.name, widget.price, widget.created_at&.to_s ]
        )
        find(db.last_insert_row_id)
      end
    end
  end

  # Base class for tests that touch the database. Each test runs inside a
  # transaction that is rolled back afterwards, keeping tests isolated.
  class DatabaseTest < Minitest::Test
    def setup
      @db = TestSupport.db
      @db.execute("BEGIN")
    end

    def teardown
      @db&.execute("ROLLBACK")
    end
  end
end

Izen.root = TestSupport.root
