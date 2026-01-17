# Self-Hosted Supabase Docker Setup

This repository contains a containerized setup for self-hosting Supabase using Docker. It includes automated configuration scripts, secure secret generation, and persistent data management using Docker volumes.

## Prerequisites

- **Docker**: Engine version 24.0+ is recommended.
- **Docker Compose**: Plugin version v2.0+.
- **Git**: To clone this repository.
- **OpenSSL**: Used for secret generation (usually pre-installed on Linux/macOS).
- **Python 3**: Used for generating pronounceable usernames and JWTs.

## Quick Start

1.  **Run the Setup Script**
    This script automates the creation of the `.env` file, generates secure random secrets (JWTs, database passwords, keys), and configures initial credentials.

    ```bash
    ./setup.sh
    ```

    *The script will copy `.env.example` to `.env` and fill in the necessary values. It also handles backing up your existing `.env` file.*

2.  **Start Services**
    Launch the Supabase stack in detached mode:

    ```bash
    docker compose up -d
    ```

3.  **Monitor Startup**
    Verify that all services are healthy. The database (`db`) may take a moment to initialize on the first run.

    ```bash
    docker compose ps
    ```

    You can check the logs if something seems wrong:

    ```bash
    docker compose logs -f db
    ```

## Accessing Services

Once all containers are running and healthy, you can access the services on your local network/host:

| Service | URL | Default Credential (User/Pass) | Description |
| :--- | :--- | :--- | :--- |
| **Studio (Dashboard)** | `http://localhost:8000` | `jutusevu` / *(See .env)* | Secure Dashboard access via Kong. Request login details from `.env` (`DASHBOARD_USERNAME`/`PASSWORD`). |
| **API Gateway** | `http://localhost:8000` | N/A | Entry point for APIs (`/rest/v1`, `/auth/v1`) and Dashboard (`/`). |
| **Postgres Database** | `localhost:5433` | `postgres` / *(See .env)* | Direct database access. Port is mapped to `POSTGRES_PORT` in `.env`. |
| **Connection Pooler** | `localhost:6432` | `postgres` / *(See .env)* | Supavisor Session Pooler. Port is mapped to `POOLER_PORT` in `.env`. |
| **Mailhog (SMTP)** (Optional) | `http://localhost:8025` | N/A | If configured, captures emails sent by Auth. |

> **Security Note**:
> - **Port 8000 (Kong)** is the only entry point for the Studio Dashboard. It protects the interface with Basic Authentication using `DASHBOARD_USERNAME` and `DASHBOARD_PASSWORD`.
> - Direct access to the Studio container is disabled for security.

> **Note**: Your specific passwords (like `POSTGRES_PASSWORD` and `DASHBOARD_PASSWORD`) are generated randomly and stored in your `.env` file. Check that file to retrieve them.

## Backup & Restore

This project includes automated scripts for backing up and restoring your data.

### Backup

Run the backup script to create a timestamped backup of your database, configuration, and files.

```bash
./scripts/backup.sh
```

**What is backed up?**
- **PostgreSQL Database**: Full dump using `pg_dumpall`, compressed as `db_dump.tar.zst` (using `zstd`).
- **Database Config**: The `db-config` volume (containing keys), compressed as `db-config.tar.zst`.
- **Storage**: The `volumes/storage` directory, compressed as `storage.tar.zst`.
- **Environment**: A copy of your `.env` file.

Backups are stored in `backups/backup_YYYYMMDD_HHMMSS/`.

### Restore

To restore from a backup, provide the path to the backup folder.

**WARNING: This will overwrite your current database and storage files!**

```bash
./scripts/restore.sh backups/backup_YYYYMMDD_HHMMSS
```

The script will automatically detect the compression format (`zstd` or `gzip`) and restore the data.

## Configuration (.env)

The `.env` file is the single source of truth for your configuration.

- **Ports**: You can customize ports (`STUDIO_PORT`, `POSTGRES_PORT`, etc.) directly in `.env`.
- **Versions**: The Postgres version can be changed via `POSTGRES_VERSION`.
- **Public URL**: If accessing from other devices on your LAN, update `SUPABASE_PUBLIC_URL` to your machine's IP address (e.g., `http://192.168.1.100:8000`).

## Stopping Services

To stop the containers but **preserve your data**:

```bash
docker compose stop
```

To stop and remove containers (data in volumes is still preserved):

```bash
docker compose down
```

## Complete Teardown & Data Removal

**WARNING: This will delete ALL your database data, users, and storage files. This action is irreversible.**

To completely remove the deployment and all associated data volumes:

1.  **Stop and remove containers + volumes**:
    ```bash
    docker compose down -v
    ```

2.  **Remove local persistent data**:
    If you want to start completely fresh (deleting all database data, uploaded files, edge functions, and generated keys), remove the locally mounted volumes.
    *Note: This requires sudo because many of these files are owned by root or container users.*

    ```bash
    # Remove database data (if any remains)
    sudo rm -rf volumes/db/data/

    # Remove uploaded files
    sudo rm -rf volumes/storage/*

    # Remove generated config keys and logs (including pgsodium root key and vector logs)
    sudo rm -rf volumes/db/config/custom/*
    ```

3.  **Reset Configuration**:
    To generate fresh passwords and secrets on the next run:
    ```bash
    rm .env
    ```

Copyright © 2026 ryumada. All Rights Reserved.

Licensed under the [MIT](LICENSE) license.
