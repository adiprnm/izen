# frozen_string_literal: true

require_relative "../test_helper"

class DatabaseTest < Minitest::Test
  def test_thread_key_is_generic
    assert_equal :database_connection, Izen::Database::THREAD_KEY
    refute_match(/izen/i, Izen::Database::THREAD_KEY.to_s)
  end

  def test_connection_is_memoized_per_thread
    main = Izen::Database.connection
    assert_same main, Izen::Database.connection

    other = Thread.new do
      connection = Izen::Database.connection
      connection.close
      connection
    end.value

    refute_same main, other
  end

  def test_sets_a_busy_timeout
    assert_equal Izen::Database::BUSY_TIMEOUT_MS, Izen::Database.connection.get_first_value("PRAGMA busy_timeout")
  end

  def test_enables_wal_and_foreign_keys
    assert_equal "wal", Izen::Database.connection.get_first_value("PRAGMA journal_mode").downcase
    assert_equal 1, Izen::Database.connection.get_first_value("PRAGMA foreign_keys")
  end
end
