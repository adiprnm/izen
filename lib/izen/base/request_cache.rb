# frozen_string_literal: true

module Izen
  module Base
    # Per-request memoization shared by app modules that have no reference to
    # the Roda app (e.g. a settings module).
    #
    # The application opens the cache in a before hook and closes it in an after
    # hook. Outside a request (Rake tasks, tests) the cache is nil, so reads go
    # straight through and nothing is cached across requests.
    #
    #   Izen::Base::RequestCache.fetch("setting:store_name") { Setting.load(...) }
    module RequestCache
      THREAD_KEY = :izen_request_cache

      module_function

      def begin!
        Thread.current[THREAD_KEY] = {}
      end

      def end!
        Thread.current[THREAD_KEY] = nil
      end

      # Returns the cached value for +key+, computing and storing it on a miss.
      # Outside a request it just yields.
      def fetch(key)
        cache = Thread.current[THREAD_KEY]
        return yield unless cache

        cache.fetch(key) { cache[key] = yield }
      end

      # Drops one key, or the whole cache when +key+ is nil. Called when a value
      # is written so the next read in the same request sees it.
      def clear(key = nil)
        cache = Thread.current[THREAD_KEY]
        return unless cache

        key.nil? ? cache.clear : cache.delete(key)
      end
    end
  end
end
