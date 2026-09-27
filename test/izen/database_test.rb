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
end
