# frozen_string_literal: true

require_relative "../test_helper"
require "timeout"

class SchedulerTest < Minitest::Test
  def setup
    Izen::Scheduler.reset!
  end

  def teardown
    Izen::Scheduler.reset!
  end

  def test_every_registers_an_entry
    task = Izen::Scheduler.every(10) { nil }

    assert_equal 1, Izen::Scheduler.tasks.size
    assert_equal 10, task[:seconds]
    assert_equal "every:1", task[:name]
  end

  def test_an_explicit_name_overrides_the_default
    task = Izen::Scheduler.every(10, name: "cleanup") { nil }

    assert_equal "cleanup", task[:name]
  end

  def test_cron_registers_a_cron_entry
    task = Izen::Scheduler.cron("0 2 * * *") { nil }

    assert_equal "cron", task[:kind]
    assert_equal %w[0 2 * * *], task[:fields]
  end

  def test_run_once_runs_every_entry
    runs = []
    Izen::Scheduler.every(10) { runs << :a }
    Izen::Scheduler.every(10) { runs << :b }

    results = Izen::Scheduler.run_once

    assert_equal [ :a, :b ], runs
    assert_equal [ "every:1", "every:2" ], results.map { |result| result[:name] }
  end

  def test_tick_runs_only_the_entries_that_are_due
    runs                         = 0
    scheduler                    = Izen::Scheduler.new(autostart: false)
    scheduler.every(300) { runs += 1 }
    now                          = Time.now

    scheduler.tick(now: now)
    scheduler.tick(now: now + 10)

    assert_equal 0, runs, "not due until the interval elapses"

    scheduler.tick(now: now + 301)

    assert_equal 1, runs

    scheduler.tick(now: now + 310)

    assert_equal 1, runs, "already ran this interval"

    scheduler.tick(now: now + 602)

    assert_equal 2, runs
  end

  def test_a_failure_in_one_entry_does_not_stop_the_others
    runs = []
    Izen::Scheduler.every(10) { raise "boom" }
    Izen::Scheduler.every(10) { runs << :ok }

    results = Izen::Scheduler.run_once

    assert_equal [ :ok ], runs
    assert_instance_of RuntimeError, results.first[:error]
  end

  def test_start_is_a_no_op_when_not_enabled
    Izen::Scheduler.every(10) { nil }

    assert_nil Izen::Scheduler.start
    refute Izen::Scheduler.started?
  end

  def test_enabled_requires_the_scheduler_env_and_a_non_test_environment
    refute Izen::Scheduler.enabled?

    ENV["SCHEDULER"] = "1"
    refute Izen::Scheduler.enabled?, "test env must stay disabled"

    ENV["APP_ENV"] = "production"
    assert Izen::Scheduler.enabled?
  ensure
    ENV.delete("SCHEDULER")
    ENV["APP_ENV"] = "test"
  end

  def test_an_autostarted_instance_runs_entries_on_a_background_thread
    queue     = Queue.new
    scheduler = Izen::Scheduler.new(poll: 0.02)
    scheduler.in(0) { queue << :ran }

    assert scheduler.running?
    Timeout.timeout(5) { assert_equal :ran, queue.pop }
  ensure
    scheduler&.shutdown
  end

  def test_cron_next_time_matches_the_next_minute
    scheduler = Izen::Scheduler.new(autostart: false)
    from      = Time.utc(2026, 1, 1, 1, 30, 0)
    next_time = scheduler.send(:next_cron_time, %w[0 2 * * *], from)

    assert_equal Time.utc(2026, 1, 1, 2, 0, 0), next_time
  end

  def test_base_job_every_schedules_perform_now
    runs = []
    job  = Class.new(Izen::Base::Job) do
      define_method(:perform) { runs << :ran }
    end

    job.every(10)
    Izen::Scheduler.run_once

    assert_equal [ :ran ], runs
  end
end
