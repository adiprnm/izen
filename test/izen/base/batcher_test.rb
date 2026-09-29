# frozen_string_literal: true

require_relative "../../test_helper"

class BatcherTest < Minitest::Test
  class Writer < Izen::Base::Batcher
    class << self
      attr_accessor :batches
    end

    self.batches = []

    def perform(batch)
      self.class.batches << batch
    end
  end

  def setup
    Writer.batches = []
  end

  def test_records_each_item_immediately_when_inline
    writer = Writer.new(inline: true)

    writer.push(:a)
    writer.push(:b)

    assert_equal [ [ :a ], [ :b ] ], Writer.batches
    assert_equal 0, writer.size
  end

  def test_push_buffers_until_flush_persists_the_batch
    writer = Writer.new

    writer.push(:a)
    writer.push(:b)

    assert_equal 0, Writer.batches.size
    assert_equal 2, writer.size

    writer.flush

    assert_equal [ [ :a, :b ] ], Writer.batches
    assert_equal 0, writer.size
  end

  def test_max_size_triggers_an_early_flush
    writer = Writer.new(max_size: 2)

    writer.push(:a)
    assert_equal 0, Writer.batches.size

    writer.push(:b)
    assert_equal [ [ :a, :b ] ], Writer.batches
  end

  def test_flush_all_persists_registered_batchers
    writer = Writer.new
    writer.push(:a)

    Izen::Base::Batcher.flush_all

    assert_includes Writer.batches, [ :a ]
  end

  def test_background_worker_flushes_on_the_interval
    writer = Writer.new(interval: 0.05)

    writer.push(:a)
    sleep 0.2

    assert_equal [ [ :a ] ], Writer.batches
  end
end
