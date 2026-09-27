# frozen_string_literal: true

require_relative "../../test_helper"

class JobTest < Minitest::Test
  class RecorderJob < Izen::Base::Job
    class << self
      attr_accessor :runs
    end

    def perform(value:)
      (self.class.runs ||= []) << value
    end
  end

  def setup
    RecorderJob.runs = []
  end

  def test_perform_now_runs_in_the_current_thread
    RecorderJob.perform_now(value: "now")

    assert_equal [ "now" ], RecorderJob.runs
  end

  def test_perform_later_runs_inline_in_tests
    RecorderJob.perform_later(value: "later")

    assert_equal [ "later" ], RecorderJob.runs
  end

  def test_run_takes_a_block
    Izen::Base::Job.run { RecorderJob.runs << "block" }

    assert_equal [ "block" ], RecorderJob.runs
  end

  def test_base_job_perform_is_abstract
    assert_raises(NotImplementedError) { Izen::Base::Job.new.perform }
  end
end
