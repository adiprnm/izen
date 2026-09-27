# frozen_string_literal: true

module Base
  # Thin wrapper around the SQLite connection, lowered from
  # `Izen::Base::Repository`.
  #
  # Concrete repositories get generated `to_model` / `to_models` overrides that
  # name the model class literally, because Spinel cannot call `.new` on a class
  # read out of a method (`model_class`).
  class Repository
    def initialize(db = nil)
      @db = db
    end

    # Resolved lazily so a memoized repository stays valid across threads.
    def db
      @db || Database.connection
    end

    def query(sql, params = [])
      db.execute(sql, normalize_params(params)).map { |row| symbolize(row) }
    end

    def find_one(sql, params = [])
      row = db.get_first_row(sql, normalize_params(params))
      row && symbolize(row)
    end

    def transaction(&block)
      db.transaction(&block)
    end

    private

    def symbolize(row)
      out                                     = {}
      row.each { |key, value| out[key.to_sym] = value }
      out
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
