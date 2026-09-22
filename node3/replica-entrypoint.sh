#!/bin/bash
# Entrypoint personalizado para los nodos secundarios (réplicas de streaming).
# Si el directorio de datos está vacío, clona el nodo primario con pg_basebackup
# y crea automáticamente standby.signal + primary_conninfo (flag -R).
set -e

PGDATA_DIR="${PGDATA:-/var/lib/postgresql/data}"

if [ -z "$(ls -A "$PGDATA_DIR" 2>/dev/null)" ]; then
  echo ">> [$(hostname)] Datos vacíos. Esperando al nodo primario ($PRIMARY_HOST)..."
  until pg_isready -h "$PRIMARY_HOST" -p 5432 -U "$REPLICATION_USER" >/dev/null 2>&1; do
    sleep 2
  done

  echo ">> [$(hostname)] Clonando datos del primario con pg_basebackup..."
  export PGPASSWORD="$REPLICATION_PASSWORD"
  pg_basebackup \
    -h "$PRIMARY_HOST" \
    -p 5432 \
    -D "$PGDATA_DIR" \
    -U "$REPLICATION_USER" \
    -Fp -Xs -P -R \
    -C -S "slot_$(hostname)"

  chmod 700 "$PGDATA_DIR"
  echo ">> [$(hostname)] Clonación completa. standby.signal creado."
fi

exec docker-entrypoint.sh postgres "$@"
