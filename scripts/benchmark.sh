#!/bin/bash
# Ejecuta pgbench contra el nodo primario con distintos niveles de
# concurrencia. Los resultados de cada corrida se guardan en backups/.
set -e
source .env

DB="$DB_NAME"
USER="$APP_USER"
OUT="backups/benchmark_$(date +%Y%m%d_%H%M%S).log"

echo ">> Inicializando datos de pgbench (escala 10)..."
docker exec -e PGPASSWORD="$APP_PASSWORD" db-node1 \
  pgbench -i -s 10 -U "$USER" -h localhost -d "$DB"

for CLIENTS in 10 25 50 100 200; do
  echo "===== Concurrencia: $CLIENTS clientes =====" | tee -a "$OUT"
  for i in 1 2 3; do
    echo "--- corrida $i ---" | tee -a "$OUT"
    docker exec -e PGPASSWORD="$APP_PASSWORD" db-node1 \
      pgbench -U "$USER" -h localhost -d "$DB" -c "$CLIENTS" -j 4 -T 30 -P 5 \
      | tee -a "$OUT"
  done
done

echo ">> Resultados guardados en $OUT"
