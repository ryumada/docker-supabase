# Database Volume

This directory is used for persistent storage of database data. When running database services via containers (e.g., Docker), this directory should be mounted to the container's internal data path to ensure that data persists across container restarts and updates.

### Configuration Example

In a `docker-compose.yml` file, map this directory to the service's data path:

```yaml
services:
  db:
    image: postgres:15
    volumes:
      - ./volumes/db:/var/lib/postgresql/data
```

### Important Notes

- **Persistence**: Deleting the contents of this directory will result in total data loss.
- **Permissions**: Ensure the host system provides the necessary read/write permissions to the user/group ID running the database process.
- **Backups**: This directory should be included in your regular backup routines.
