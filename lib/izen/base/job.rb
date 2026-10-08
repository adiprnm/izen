# frozen_string_literal: true

module Izen
  module Base
    # Background job base class and single-threaded worker.
    #
    # Subclasses implement #perform and are enqueued with:
    #
    #   MyJob.perform_later(id: 1)   # run on the background worker
    #   MyJob.perform_now(id: 1)     # run in the current thread (tests)
    #
    # One-off work can be enqueued directly with `Base::Job.run { ... }`. In tests
    # (or when JOBS_INLINE=1) everything runs synchronously.
    class Job
      @queue  = Queue.new
      @inline = false
      @worker = nil

      class << self
        attr_writer :inline

        def inline?
          @inline || ENV["JOBS_INLINE"] == "1"
        end

        # Enqueues a block on the shared worker.
        def run(&block)
          enqueue(&block)
        end

        # Instantiates the job and runs #perform in the current thread.
        def perform_now(*args, **kwargs)
          new.perform(*args, **kwargs)
        end

        # Instantiates the job and enqueues #perform on the shared worker.
        def perform_later(*args, **kwargs)
          Base::Job.enqueue { new.perform(*args, **kwargs) }
        end

        # Adds a block to the worker queue. Public so subclasses can use it.
        def enqueue(&block)
          if inline?
            block.call
          else
            @queue << block
            ensure_worker
            nil
          end
        end

        # Schedules #perform_now every +interval+ seconds on Izen::Scheduler.
        # The scheduler is opt-in (SCHEDULER=1); registering is always safe.
        def every(interval, name: nil)
          Izen::Scheduler.every(interval, name: name || "job:#{self}") { perform_now }
        end

        private

        def ensure_worker
          return if @worker&.alive?

          @worker = Thread.new do
            Thread.current.abort_on_exception = false
            loop do
              job = @queue.pop
              begin
                job.call
              rescue StandardError => e
                warn "[Job] #{e.class}: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}"
              ensure
                Database.disconnect
              end
            end
          end
        end
      end

      # Subclasses must implement this.
      def perform
        raise NotImplementedError, "#{self.class} must implement #perform"
      end
    end
  end
end
