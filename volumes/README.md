# Volumes Directory

This directory is used for persistent data storage, typically mapped as volumes for containerized services.

## Usage

- Each subdirectory should correspond to a specific service or volume mount.
- Data stored here persists across container restarts and recreations.

## Git Policy

To prevent large data files or sensitive information from being committed to the repository, ensure that the contents of this directory (except for this `README.md`) are included in your `.gitignore`.
