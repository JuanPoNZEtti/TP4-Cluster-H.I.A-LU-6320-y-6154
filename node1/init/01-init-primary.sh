#!/bin/bash
# Se ejecuta automáticamente en el primer arranque del nodo primario
# (docker-entrypoint-initdb.d). Crea usuarios diferenciados y permisos mínimos.
set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    -- Usuario de replicación: solo puede abrir conexiones de streaming replication
    CREATE ROLE ${REPLICATION_USER} WITH REPLICATION LOGIN PASSWORD '${REPLICATION_PASSWORD}';

    -- Usuario de aplicación: acceso de lectura/escritura solo a la base de datos de trabajo
    CREATE ROLE ${APP_USER} WITH LOGIN PASSWORD '${APP_PASSWORD}';
    GRANT ALL PRIVILEGES ON DATABASE ${POSTGRES_DB} TO ${APP_USER};

    -- Usuario de monitorización: solo lectura de métricas (rol pg_monitor de Postgres)
    CREATE ROLE ${MONITOR_USER} WITH LOGIN PASSWORD '${MONITOR_PASSWORD}';
    GRANT pg_monitor TO ${MONITOR_USER};
EOSQL

# Permisos sobre el esquema public para el usuario de aplicación
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    GRANT ALL ON SCHEMA public TO ${APP_USER};
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO ${APP_USER};
EOSQL

# Reglas de acceso: solo dentro de la red interna de Docker (172.16.0.0/12 cubre el rango por defecto de compose)
{
  echo "host replication ${REPLICATION_USER} 172.16.0.0/12 scram-sha-256"
  echo "host all ${APP_USER}          172.16.0.0/12 scram-sha-256"
  echo "host all ${MONITOR_USER}      172.16.0.0/12 scram-sha-256"
  echo "host all ${ADMIN_USER}        172.16.0.0/12 scram-sha-256"
} >> "$PGDATA/pg_hba.conf"

echo "Nodo primario inicializado: usuarios y pg_hba.conf configurados."
