# frozen_string_literal: true

require_relative "../database"

module Izen
  module Base
    # Thin wrapper around the SQLite connection.
    #
    # Subclasses talk to the database with plain SQL and translate rows into
    # models. Creating, updating and deleting records all receive a model.
    class Repository
      def initialize(db = nil)
        @db = db
      end

      # The connection is resolved lazily (per thread) unless one was injected,
      # so a memoized repository instance stays safe across threads.
      def db
        @db || Database.connection
      end

      # Returns an array of symbol-keyed hashes.
      def query(sql, params = [])
        db.execute(sql, normalize_params(params)).map { |row| symbolize(row) }
      end

      # Returns a single symbol-keyed hash, or nil.
      def find_one(sql, params = [])
        row = db.get_first_row(sql, normalize_params(params))
        row && symbolize(row)
      end

      # Convenience helpers that build the module's model.
      def to_model(row)
        row && model_class.new(row)
      end

      def to_models(rows)
        rows.map { |row| model_class.new(row) }
      end

      # Resolves `BlogPost::Repository` to `BlogPost::Model`.
      def model_class
        namespace = self.class.name.to_s.split("::")[0...-1].join("::")
        Object.const_get("#{namespace}::Model")
      end

      # SQLite has no nested transactions; when a caller (e.g. a test) already
      # opened one, just run the block in place.
      def transaction(&block)
        return yield if db.transaction_active?

        db.transaction(&block)
      end

      # Formats a Time for a SQLite DATETIME column.
      #
      # `Time#to_s` appends a " UTC" suffix SQLite's date functions cannot
      # parse, so write the "YYYY-MM-DD HH:MM:SS.ffffff" form SQLite and Sequel
      # use -- the form `datetime()` accepts. Calls strftime directly rather
      # than probing respond_to? (Spinel's respond_to? misses Time#strftime).
      def sqlite_time(value)
        return nil if value.nil?

        value.strftime("%Y-%m-%d %H:%M:%S.%6N")
      end

      private

      def symbolize(row)
        row.transform_keys(&:to_sym)
      end

      # Roda/Rack capture path segments as ASCII-8BIT; SQLite would bind those as
      # BLOBs and fail to match TEXT columns. Force UTF-8 on bound strings.
      def normalize_params(params)
        Array(params).map do |param|
          param.is_a?(String) ? param.dup.force_encoding(Encoding::UTF_8) : param
        end
      end
    end
  end
end
