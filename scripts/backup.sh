#!/bin/bash
# Backup lógico (pg_dump) del nodo primario.
set -e
source .env

TS=$(date +%Y%m%d_%H%M%S)
FILE="backup_${TS}.dump"

docker exec -e PGPASSWORD="$APP_PASSWORD" db-node1 \
  pg_dump -U "$APP_USER" -h localhost -d "$DB_NAME" -F c -f "/backups/${FILE}"

echo ">> Backup creado en backups/${FILE}"
