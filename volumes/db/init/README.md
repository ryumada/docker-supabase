# Database Initialization

This directory (`volumes/db/init/`) contains SQL scripts that are automatically executed when the Postgres container starts **with an empty database**.

## How to use `data.sql`

To seed your database with initial data or create custom tables/roles that Supabase doesn't create by default, you need to create a `data.sql` file.

1.  **Create File**: Copy the example file to get started:
    ```bash
    cp data.sql.example data.sql
    ```
2.  **Edit `data.sql`**: Add your custom SQL queries to this file.
    *   Example: creating a new table, inserting initial rows, creating a custom role.
3.  **Restart**: Run `docker compose restart db`.
    *   *Note: If the database volume (`volumes/db/data`) already exists and contains data, scripts in this folder might NOT run again. You may need to manually run them or reset your database.*

## File Order
Scripts are executed in alphabetical order.
*   `data.sql`
*   Any other `.sql` file you add here.
