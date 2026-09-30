# frozen_string_literal: true

require "monitor"

# Spinel FFI bindings to sqlite3 (through the C shim in sqlite_shim.c).
#
# This file is only compiled in the Spinel build — it uses the `ffi_*` DSL,
# which does not exist on CRuby. The generated project keeps it under `spinel/`
# and the spin build picks up `sqlite_shim.c` from the same directory.
#
# See https://github.com/matz/spinel/blob/master/docs/FFI.md.
module Sqlite
  ffi_lib "sqlite3"

  ffi_const :OK,   0
  ffi_const :ROW,  100
  ffi_const :DONE, 101

  ffi_func :shim_open,         [ :str, :ptr ],            :int
  ffi_func :shim_close,        [ :ptr ],                  :int
  ffi_func :shim_exec,         [ :ptr, :str ],            :int
  ffi_func :shim_prepare,      [ :ptr, :str ],            :ptr
  ffi_func :shim_bind_text,    [ :ptr, :int, :str ],      :int
  ffi_func :shim_bind_int,     [ :ptr, :int, :long ],     :int
  ffi_func :shim_bind_null,    [ :ptr, :int ],            :int
  ffi_func :shim_step,         [ :ptr ],                  :int
  ffi_func :shim_column_type,  [ :ptr, :int ],            :long
  ffi_func :shim_column_text,  [ :ptr, :int ],            :str
  ffi_func :shim_column_int,   [ :ptr, :int ],            :long
  ffi_func :shim_column_count, [ :ptr ],                  :int
  ffi_func :shim_column_name,  [ :ptr, :int ],            :str
  ffi_func :shim_reset,        [ :ptr ],                  :int
  ffi_func :shim_finalize,     [ :ptr ],                  :int
  ffi_func :shim_errmsg,       [ :ptr ],                  :str
  ffi_func :shim_last_insert_rowid, [ :ptr ],             :long

  ffi_buffer :db_out, 8
  ffi_read_ptr :read_ptr, 0
end

# Adapter with the same surface as SQLite3::Database (execute / get_first_row /
# get_first_value / transaction), implemented over the FFI calls above.
class SqliteAdapter
  def initialize(path)
    raise "cannot open #{path}" unless Sqlite.shim_open(path, Sqlite.db_out) == Sqlite::OK

    @db      = Sqlite.read_ptr(Sqlite.db_out)
    @monitor = Monitor.new
  end

  def execute(sql, params = [])
    @monitor.synchronize { run(sql, params) }
  end

  def get_first_row(sql, params = [])
    @monitor.synchronize { execute(sql, params).first }
  end

  def get_first_value(sql, params = [])
    @monitor.synchronize do
      row = execute(sql, params).first
      row && row.values.first
    end
  end

  def transaction
    @monitor.synchronize do
      # Nested `transaction` blocks join the outer one (Sequel's default), so a
      # repository that seeds inside its own transaction does not hit SQLite's
      # "cannot start a transaction within a transaction".
      if @transaction_depth.to_i > 0
        @transaction_depth += 1
        result              = yield
        @transaction_depth -= 1
        result
      else
        @transaction_depth = 1
        execute("BEGIN")
        begin
          result             = yield
          execute("COMMIT")
          @transaction_depth = 0
          result
        rescue StandardError
          @transaction_depth = 0
          # Release the write lock even when the block failed. A failing
          # ROLLBACK must not mask the original error.
          begin
            execute("ROLLBACK")
          rescue StandardError
            nil
          end
          raise
        end
      end
    end
  end

  def execute_batch(sql)
    @monitor.synchronize { Sqlite.shim_exec(@db, sql) }
  end

  def close
    @monitor.synchronize { Sqlite.shim_close(@db) }
  end

  private

  def run(sql, params)
    stmt = prepare(sql, params)
    rows = []
    begin
      loop do
        code = Sqlite.shim_step(stmt)
        break if code == Sqlite::DONE
        raise Sqlite.shim_errmsg(@db) unless code == Sqlite::ROW

        rows << current_row(stmt)
      end
    ensure
      # Always finalize. A statement left open after a failed step (a busy
      # SQLITE_BUSY, say) keeps its lock on the database and makes every later
      # COMMIT fail with "SQL statements in progress", poisoning the
      # connection for the rest of the process's life.
      Sqlite.shim_finalize(stmt)
    end
    rows
  end

  private

  def prepare(sql, params)
    stmt = Sqlite.shim_prepare(@db, sql)
    raise Sqlite.shim_errmsg(@db) unless stmt

    params.each_with_index do |value, index|
      i = index + 1
      case value
      when nil     then Sqlite.shim_bind_null(stmt, i)
      when Integer then Sqlite.shim_bind_int(stmt, i, value)
      else              Sqlite.shim_bind_text(stmt, i, value.to_s)
      end
    end
    stmt
  end

  def current_row(stmt)
    row   = {}
    count = Sqlite.shim_column_count(stmt)
    index = 0
    while index < count
      name = Sqlite.shim_column_name(stmt, index)
      type = Sqlite.shim_column_type(stmt, index)
      cell = if type == 5
        nil
      elsif type == 1 || type == 2
        Sqlite.shim_column_int(stmt, index)
      else
        Sqlite.shim_column_text(stmt, index)
      end
      row[name] = if cell.nil?
        nil
      elsif cell.is_a?(String)
        cell.dup
      else
        cell
      end
      index    += 1
    end
    row
  end
end
