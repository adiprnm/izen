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

    # SQLite stores timestamps as text. Time#to_s appends a " UTC" suffix its
    # date functions cannot parse, so write the "YYYY-MM-DD HH:MM:SS.ffffff"
    # form SQLite and Sequel write. (strftime is called directly: Spinel's
    # respond_to? does not see Time#strftime.)
    def sqlite_time(value)
      return nil if value.nil?

      value.strftime("%Y-%m-%d %H:%M:%S.%6N")
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
