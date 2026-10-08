# frozen_string_literal: true

module Izen
  # Recurring task scheduler.
  #
  # A Scheduler holds periodic entries and fires the ones that are due from a
  # single background thread. It is the plain-Ruby replacement for the
  # `rufus-scheduler` dependency the generated native runtime used to shim:
  # the same instance API (`new` + #every/#cron/#in/#shutdown), implemented in
  # the Ruby subset that runs on CRuby and under Spinel alike.
  #
  #   scheduler = Izen::Scheduler.new
  #   scheduler.every(300) { Order::Expiration.new.call }
  #   scheduler.cron("0 2 * * *") { Backups::Manager.run }
  #
  # A new instance starts itself on the first registration. The class-level
  # helpers drive one shared instance instead, and that is what the scaffolded
  # `config.ru` starts:
  #
  #   Izen::Scheduler.every(300) { ... } # register on the shared instance
  #   Izen::Scheduler.start             # no-op unless SCHEDULER=1, never in test
  #
  # `Izen::Base::Job.every` is shorthand for scheduling a job's #perform_now.
  #
  # Enable it in one process only: keep Puma in single mode (WEB_CONCURRENCY=0,
  # the scaffolded default) and deploy a single web container. Entries are
  # expected to be idempotent, so the brief overlap of two containers during a
  # rolling deploy is harmless.
  class Scheduler
    POLL_SECONDS = 10
    SEARCH_LIMIT = 366 * 24 * 60 # minutes to scan forward for a cron match

    class << self
      # The shared instance the class-level helpers operate on.
      def default
        @default ||= new(autostart: false)
      end

      def every(interval, options = nil, name: nil, &block)
        default.every(interval, options, name: name, &block)
      end

      def cron(expression, options = nil, name: nil, &block)
        default.cron(expression, options, name: name, &block)
      end

      def in(interval, options = nil, name: nil, &block)
        default.in(interval, options, name: name, &block)
      end

      def tasks
        default.tasks
      end

      def started?
        default.running?
      end

      # True when the scheduler is opted in and not running under the test env.
      def enabled?
        ENV["SCHEDULER"] == "1" && Izen::Database.env != "test"
      end

      # Starts the shared scheduler when enabled. No-op otherwise (returns nil).
      def start
        return default if started?
        return nil unless enabled?

        default.start
      end

      # Starts the shared scheduler regardless of SCHEDULER (tests, boot scripts).
      def start!
        default.start
      end

      def stop
        default.shutdown
      end

      # Stops the shared scheduler and forgets its entries (tests).
      def reset!
        stop
        @default = nil
      end

      def tick(now: Time.now)
        default.tick(now: now)
      end

      def run_once(now: Time.now)
        default.run_once(now: now)
      end
    end

    attr_reader :tasks

    def initialize(autostart: true, poll: POLL_SECONDS)
      @tasks     = []
      @running   = false
      @autostart = autostart
      @poll      = poll
      @mutex     = Mutex.new
      @thread    = nil
    end

    # Registers a repeating entry (seconds, or a string like "5m").
    def every(interval, _options = nil, name: nil, &block)
      seconds = parse_interval(interval)
      add(kind: "every", seconds: seconds, block: block, name: name, next_at: Time.now + seconds)
    end

    # Registers a cron entry (standard five-field expression, UTC).
    def cron(expression, _options = nil, name: nil, &block)
      add(kind: "cron", fields: expression.to_s.split, block: block, name: name)
    end

    # Registers a one-shot entry that runs once, +interval+ seconds from now.
    def in(interval, _options = nil, name: nil, &block)
      seconds = parse_interval(interval)
      add(kind: "in", block: block, name: name, next_at: Time.now + seconds)
    end

    def running?
      @running
    end

    # Starts the background thread. Idempotent.
    def start
      return self if @running

      @running = true
      @thread  = Thread.new do
        Thread.current.name               = "izen-scheduler"
        Thread.current.abort_on_exception = false
        while @running
          sleep @poll
          tick
        end
      end
      self
    end

    # Stops the background thread. Safe to call when it is not running.
    def shutdown
      @running = false
      @thread&.kill
      @thread  = nil
    end

    # Runs the entries that are due at +now+ in the current thread. Returns one
    # { name:, duration:, error: } result per entry that ran.
    def tick(now: Time.now)
      due = []
      @mutex.synchronize do
        @tasks.each do |task|
          next if task[:next_at].nil? || task[:next_at] > now

          due << task
          task[:next_at] =
            case task[:kind]
            when "in"    then nil
            when "every" then now + task[:seconds]
            else next_cron_time(task[:fields], now)
            end
        end
      end

      due.map { |task| run_task(task, now) }
    end

    # Runs every entry once, due or not (manual runs, tests).
    def run_once(now: Time.now)
      @tasks.map { |task| run_task(task, now) }
    end

    private

    def add(task)
      task[:next_at] ||= next_cron_time(task[:fields], Time.now)
      task[:name]    ||= "#{task[:kind]}:#{@tasks.size + 1}"
      @mutex.synchronize { @tasks << task }
      start if @autostart
      task
    end

    def run_task(task, now)
      started  = Time.now
      task[:block].call
      duration = Time.now - started
      warn "[izen] scheduler #{task[:name]} ok in #{(duration * 1000).to_i}ms"
      { name: task[:name], duration: duration, error: nil }
    rescue StandardError => error
      duration = Time.now - started
      warn "[izen] scheduler #{task[:name]} failed in #{(duration * 1000).to_i}ms: #{error.class}: #{error.message}"
      warn Array(error.backtrace).first(5).join("\n")
      { name: task[:name], duration: duration, error: error }
    end

    def parse_interval(interval)
      case interval
      when Integer then interval
      when Float then interval.to_i
      when String then interval.to_i
      else 60
      end
    end

    # Next time (UTC, minute granularity) the five-field cron expression matches,
    # scanning forward one minute at a time.
    def next_cron_time(fields, from)
      return from + 60 if fields.nil? || fields.length < 5

      time  = Time.utc(from.year, from.month, from.day, from.hour, from.min, 0) + 60
      limit = time + SEARCH_LIMIT * 60

      while time < limit
        if field_match?(fields[0], time.min) &&
           field_match?(fields[1], time.hour) &&
           field_match?(fields[2], time.day) &&
           field_match?(fields[3], time.month) &&
           field_match?(fields[4], time.strftime("%w").to_i)
          return time
        end
        time = time + 60
      end
      from + 86_400
    end

    # Supports `*`, `a`, `a-b`, `*/n`, `a-b/n` and comma lists.
    def field_match?(field, value)
      return true if field == "*"

      field.split(",").any? do |part|
        base = part
        step = 1
        if part.include?("/")
          pieces = part.split("/", 2)
          base   = pieces[0]
          step   = pieces[1].to_i
          step   = 1 if step <= 0
        end

        if base == "*"
          (value % step).zero?
        elsif base.include?("-")
          ends  = base.split("-", 2)
          first = ends[0].to_i
          last  = ends[1].to_i
          value >= first && value <= last && ((value - first) % step).zero?
        else
          base.to_i == value
        end
      end
    end
  end
end
