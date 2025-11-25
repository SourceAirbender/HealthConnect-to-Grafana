import os
import sqlite3
import psycopg2
from psycopg2 import sql
from datetime import datetime
from dotenv import load_dotenv

# Load .env file if present
load_dotenv()

# REQUIRED ENV VARS
REQUIRED_ENV_VARS = [
    "SQLITE_DB_PATH",
    "LOG_FILE",
    "PGHOST",
    "PGPORT",
    "PGDATABASE",
    "PGUSER",
    "PGPASSWORD",
]

# DEFAULT TABLES (can be overridden via TABLES_TO_IMPORT env var)
DEFAULT_TABLES = {
    "steps_record_table",
    "body_fat_record_table",
    "weight_record_table",
    "speed_record_table",
    "sleep_session_record_table",
    "distance_record_table",
}


def log(message: str):
    log_file = os.getenv("LOG_FILE")

    if not log_file:
        # Last resort: print only
        print(f"[NO_LOG_FILE] {message}")
        return

    log_dir = os.path.dirname(log_file)
    if log_dir and not os.path.exists(log_dir):
        os.makedirs(log_dir, exist_ok=True)

    with open(log_file, "a") as f:
        timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        f.write(f"[{timestamp}] {message}\n")
    print(message)


def check_required_env():
    missing = [var for var in REQUIRED_ENV_VARS if not os.getenv(var)]
    if missing:
        print("Missing required environment variables:")
        for var in missing:
            print(f"  - {var}")
        print("Set them in your .env or environment and try again.")
        return False
    return True


def get_config():
    sqlite_db_path = os.getenv("SQLITE_DB_PATH")
    log_file = os.getenv("LOG_FILE")

    postgres_config = {
        "host": os.getenv("PGHOST"),
        "port": int(os.getenv("PGPORT")),
        "database": os.getenv("PGDATABASE"),
        "user": os.getenv("PGUSER"),
        "password": os.getenv("PGPASSWORD"),
    }

    tables_env = os.getenv("TABLES_TO_IMPORT", "").strip()
    if tables_env:
        tables_to_import = {t.strip() for t in tables_env.split(",") if t.strip()}
    else:
        tables_to_import = DEFAULT_TABLES

    return sqlite_db_path, log_file, postgres_config, tables_to_import


def get_create_table_query(table, cursor):
    cursor.execute(f"PRAGMA table_info({table})")
    columns = cursor.fetchall()
    col_defs = []

    for col in columns:
        col_name = col[1]
        col_type = (col[2] or "").upper()

        if col_type == "":
            mapped = "TEXT"
        elif col_type.startswith("INT"):
            mapped = "BIGINT"
        elif col_type.startswith("REAL"):
            mapped = "DOUBLE PRECISION"
        elif col_type.startswith("BLOB"):
            mapped = "BYTEA"
        else:
            mapped = "TEXT"

        col_defs.append(f'"{col_name}" {mapped}')

    create_sql = f'CREATE TABLE IF NOT EXISTS "{table}" ({", ".join(col_defs)});'
    column_names = [col[1] for col in columns]
    return create_sql, column_names


def sync_table(table, sqlite_cursor, pg_cursor, pg_conn, tables_to_import):
    if table not in tables_to_import:
        log(f"Skipping `{table}` (not in selected list).")
        return

    try:
        create_query, column_names = get_create_table_query(table, sqlite_cursor)
        log(f"Ensuring table `{table}` exists in PostgreSQL.")
        pg_cursor.execute(create_query)
        pg_conn.commit()
    except Exception as e:
        log(f"Error creating table `{table}`: {e}")
        return

    try:
        sqlite_cursor.execute(f"SELECT * FROM {table}")
        rows = sqlite_cursor.fetchall()
    except Exception as e:
        log(f"Failed to fetch from SQLite table `{table}`: {e}")
        return

    dedup_col = None
    for col in ["row_id", "local_date_time", "time"]:
        if col in column_names:
            dedup_col = col
            break

    existing_keys = set()
    if dedup_col:
        try:
            pg_cursor.execute(sql.SQL("SELECT {} FROM {}").format(
                sql.Identifier(dedup_col),
                sql.Identifier(table)
            ))
            existing_keys = {row[0] for row in pg_cursor.fetchall()}
        except Exception as e:
            log(f"Warning: Failed to fetch existing keys for `{table}`: {e}")
            existing_keys = set()

    new_rows = []
    already_present = 0

    for row in rows:
        if dedup_col:
            idx = column_names.index(dedup_col)
            if row[idx] in existing_keys:
                already_present += 1
                continue
        new_rows.append(row)

    if new_rows:
        column_list = ", ".join([f'"{col}"' for col in column_names])
        placeholders = ", ".join(["%s"] * len(column_names))
        insert_query = f'INSERT INTO "{table}" ({column_list}) VALUES ({placeholders})'

        valid_rows = []
        skipped_rows = 0

        for i, row in enumerate(new_rows):
            if len(row) < len(column_names):
                skipped_rows += 1
                log(f"⚠️ Row {i} skipped in `{table}`: expected at least {len(column_names)} columns, got {len(row)}")
                log(f"⚠️ Skipped data: {row}")
                continue
            valid_rows.append(tuple(row[:len(column_names)]))  # truncate excess

        if valid_rows:
            try:
                pg_cursor.executemany(insert_query, valid_rows)
                pg_conn.commit()
                log(f"Inserted {len(valid_rows)} new rows into `{table}`.")
            except Exception as e:
                pg_conn.rollback()
                log(f"❌ Error inserting into `{table}`: {e}")
                if valid_rows:
                    log(f"Sample row: {valid_rows[0]}")
        else:
            log(f"No valid rows to insert for `{table}`.")

        if skipped_rows:
            log(f"⚠️ {skipped_rows} rows skipped due to insufficient column count in `{table}`.")
    else:
        log(f"No new rows to insert for `{table}`.")

    log(f"{already_present} rows already existed in `{table}`.")


def main():
    if not check_required_env():
        return

    sqlite_db_path, log_file, postgres_config, tables_to_import = get_config()

    if not os.path.exists(sqlite_db_path):
        log(f"SQLite DB not found at {sqlite_db_path}")
        return

    log("Starting selective table sync...")

    sqlite_conn = sqlite3.connect(sqlite_db_path)
    sqlite_cursor = sqlite_conn.cursor()

    try:
        pg_conn = psycopg2.connect(**postgres_config)
        pg_cursor = pg_conn.cursor()
    except Exception as e:
        log(f"Error connecting to PostgreSQL: {e}")
        sqlite_conn.close()
        return

    sqlite_cursor.execute("SELECT name FROM sqlite_master WHERE type='table';")
    all_tables = [row[0] for row in sqlite_cursor.fetchall()]

    for table in all_tables:
        try:
            sync_table(table, sqlite_cursor, pg_cursor, pg_conn, tables_to_import)
        except Exception as e:
            log(f"Unhandled error syncing `{table}`: {e}")

    pg_cursor.close()
    pg_conn.close()
    sqlite_conn.close()
    log("Selective table sync complete.\n")


if __name__ == "__main__":
    main()
