# Google Health / Health Connect SQLite → PostgreSQL Importer for Grafana

This is a small setup to get my Google Health / Health Connect data into PostgreSQL and then into Grafana.

Google gives you a `.db` SQLite file. I want charts in Grafana.  
handles:
- importing selected tables from the Google Health `.db` into Postgres
- running the import on a schedule via a systemd service + timer
- keeping everything configurable from .env


script:
- Auto-creates matching tables in PostgreSQL based on the provided SQLite schema
- Imports only the tables you care about (steps, weight, sleep, etc.)
- Deduplicates rows based on one of:
  - `row_id`

  - `local_date_time`
  - `time`
- Can be run manually or automatically on a schedule using a systemd timer

Google automatically exports the health .db file to my googledrive, I set that up to push the file to my server in the folder the script runs from.
So, have a way to sync new daily .db files to the folder, let the importer run daily, and your Grafana dashboards update automatically.

install script, `install.sh`  
  Installer for:
  - Python venv
  - Python dependencies
  - OS packages (`postgresql-client`, `pgloader`, etc.)
  - systemd service + timer

- `uninstall.sh`  
  Cleans up the systemd service and timer.
