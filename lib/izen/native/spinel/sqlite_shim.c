/*
 * sqlite_shim.c — bound-parameter helpers for the Spinel build.
 *
 * Spinel's FFI cannot yet build the SQLITE_TRANSIENT sentinel (`(void *)-1`)
 * that `sqlite3_bind_text` needs, so this thin C helper bakes it in and exposes
 * only plain scalar/pointer signatures the FFI layer can declare. See
 * https://github.com/matz/spinel/blob/master/docs/FFI.md.
 *
 * Compile/link with `-lsqlite3` (declared by `ffi_lib "sqlite3"` in
 * sqlite_ffi.rb).
 */
#include <stdint.h>
#include <sqlite3.h>

/* Opens `path`; writes the handle into *out. Returns the sqlite3 result code. */
intptr_t shim_open(const char *path, void *out) {
  sqlite3 *db = 0;
  int rc = sqlite3_open(path, &db);
  *(sqlite3 **)out = db;
  return (intptr_t)rc;
}

intptr_t shim_close(sqlite3 *db) { return (intptr_t)sqlite3_close(db); }

sqlite3_stmt *shim_prepare(sqlite3 *db, const char *sql) {
  sqlite3_stmt *stmt = 0;
  if (sqlite3_prepare_v2(db, sql, -1, &stmt, 0) != SQLITE_OK) return 0;
  return stmt;
}

intptr_t shim_bind_text(sqlite3_stmt *stmt, int64_t idx, const char *value) {
  return (intptr_t)sqlite3_bind_text(stmt, (int)idx, value, -1, SQLITE_TRANSIENT);
}

intptr_t shim_bind_int(sqlite3_stmt *stmt, int64_t idx, int64_t value) {
  return (intptr_t)sqlite3_bind_int64(stmt, (int)idx, value);
}

intptr_t shim_bind_null(sqlite3_stmt *stmt, int64_t idx) {
  return (intptr_t)sqlite3_bind_null(stmt, (int)idx);
}

intptr_t shim_step(sqlite3_stmt *stmt) { return (intptr_t)sqlite3_step(stmt); }

int64_t shim_column_type(sqlite3_stmt *stmt, int64_t col) {
  return (int64_t)sqlite3_column_type(stmt, (int)col);
}

const char *shim_column_text(sqlite3_stmt *stmt, int64_t col) {
  return (const char *)sqlite3_column_text(stmt, (int)col);
}

int64_t shim_column_int(sqlite3_stmt *stmt, int64_t col) {
  return (int64_t)sqlite3_column_int64(stmt, (int)col);
}

intptr_t shim_column_count(sqlite3_stmt *stmt) {
  return (intptr_t)sqlite3_column_count(stmt);
}

const char *shim_column_name(sqlite3_stmt *stmt, int64_t col) {
  return sqlite3_column_name(stmt, (int)col);
}

intptr_t shim_reset(sqlite3_stmt *stmt) { return (intptr_t)sqlite3_reset(stmt); }

intptr_t shim_finalize(sqlite3_stmt *stmt) { return (intptr_t)sqlite3_finalize(stmt); }

const char *shim_errmsg(sqlite3 *db) { return sqlite3_errmsg(db); }

intptr_t shim_exec(sqlite3 *db, const char *sql) {
  return (intptr_t)sqlite3_exec(db, sql, 0, 0, 0);
}

int64_t shim_last_insert_rowid(sqlite3 *db) {
  return (int64_t)sqlite3_last_insert_rowid(db);
}
