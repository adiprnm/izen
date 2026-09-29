# frozen_string_literal: true

module Izen
  module Base
    # Write-behind buffer: collect items in memory and persist them in batches
    # from a background worker.
    #
    # Subclass it and implement #perform(batch), which receives the accumulated
    # items. It runs in the worker thread, so a database connection resolved
    # inside it is the worker's own (see Izen::Database).
    #
    #   class ViewWriter < Izen::Base::Batcher
    #     def perform(batch)
    #       db.transaction { batch.each { |row| db.execute(INSERT, row) } }
    #     end
    #   end
    #
    #   VIEWS = ViewWriter.new(interval: 2)
    #   VIEWS.push(row)   # returns immediately, no disk write
    #
    # For fire-and-forget data (analytics, logs, metrics): the point is to turn
    # N slow commits (one fsync each) into one commit per batch. The buffer
    # lives in memory, so items not yet flushed are lost on SIGKILL/crash; a
    # graceful shutdown flushes them. Not for transactional data.
    class Batcher
      DEFAULT_INTERVAL = 2   # seconds between flushes
      DEFAULT_MAX_SIZE = 500 # flush early once this many items are buffered

      REGISTRY       = []
      REGISTRY_MUTEX = Mutex.new

      class << self
        # Every instance registers itself so a graceful shutdown can flush it.
        def register(batcher)
          REGISTRY_MUTEX.synchronize { REGISTRY << batcher }
          nil
        end

        # Persists every registered batcher's pending items (called on shutdown).
        def flush_all
          batchers = REGISTRY_MUTEX.synchronize { REGISTRY.dup }
          batchers.each { |batcher| batcher.flush }
          nil
        end
      end

      def initialize(interval: DEFAULT_INTERVAL, max_size: DEFAULT_MAX_SIZE, inline: false)
        @interval = interval
        @max_size = max_size
        @inline   = inline
        @buffer   = []
        @mutex    = Mutex.new
        @worker   = nil
        Batcher.register(self)
      end

      # Adds an item and returns immediately; it is persisted on the next flush.
      def push(item)
        if inline?
          perform([ item ])
          return nil
        end

        @mutex.synchronize { @buffer << item }
        ensure_worker
        flush if size >= @max_size
        nil
      end

      # Persists everything buffered right now. Safe to call from any thread:
      # the first caller drains the buffer, the rest see it empty.
      def flush
        batch = @mutex.synchronize do
          rows    = @buffer
          @buffer = []
          rows
        end
        return nil if batch.empty?

        perform(batch)
        nil
      rescue StandardError => error
        $stderr.puts("[izen] batcher flush failed: #{error.message}")
        nil
      end

      # Number of items waiting to be flushed.
      def size
        @mutex.synchronize { @buffer.size }
      end

      # Override in subclasses to persist a batch.
      def perform(_batch)
        raise NotImplementedError, "#{self.class}#perform must persist the batch"
      end

      private

      def inline?
        @inline || ENV["BATCHERS_INLINE"] == "1"
      end

      def ensure_worker
        @mutex.synchronize do
          return if @worker && @worker.alive?

          @worker = Thread.new do
            loop do
              sleep @interval
              flush
            end
          end
        end
      end
    end
  end
end
