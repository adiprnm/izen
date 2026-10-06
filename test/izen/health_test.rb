# frozen_string_literal: true

require_relative "../test_helper"

class HealthTest < TestSupport::DatabaseTest
  def setup
    super
    @db.execute("CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY, applied_at TEXT)")
    @db.execute("DELETE FROM schema_migrations")
    @db.execute("INSERT INTO schema_migrations (version) VALUES (24)")
  end

  def test_reports_ok_and_the_latest_migration
    result = Izen::Health.call

    assert_equal "ok", result[:status]
    assert_equal "ok", result[:database]
    assert_equal 24, result[:migration]
    assert Izen::Health.ok?
  end
end
