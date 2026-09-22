#!/bin/bash
# Promueve una réplica a primario (failover manual).
# Uso: ./scripts/promote-replica.sh db-node2
set -e
NODE=${1:-db-node2}

echo ">> Promoviendo $NODE a primario..."
docker exec -u postgres "$NODE" psql -c "SELECT pg_promote();"

sleep 2
echo ">> Estado tras la promoción:"
docker exec -u postgres "$NODE" psql -c "SELECT pg_is_in_recovery();"

echo ">> HAProxy debería detectar el cambio en unos segundos (healthcheck cada 3s)."
echo ">> Verificar en: http://localhost:8404/stats"
