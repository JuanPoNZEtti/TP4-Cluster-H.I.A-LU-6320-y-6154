#!/bin/bash
# Automatiza los escenarios de prueba de operatividad (A, B, C, D)
set -e

echo "======================================================"
echo " ESCENARIO A: todos los nodos activos"
echo "======================================================"
docker ps --filter "name=db-node" --format "table {{.Names}}\t{{.Status}}"
docker exec -u postgres db-node1 psql -c "SELECT client_addr, state, sync_state FROM pg_stat_replication;"

echo ""
echo "======================================================"
echo " ESCENARIO B: apagar nodo secundario (db-node3)"
echo "======================================================"
docker stop db-node3
sleep 8
echo "Réplicas visibles en el primario:"
docker exec -u postgres db-node1 psql -c "SELECT client_addr, state FROM pg_stat_replication;"
echo "Revisar http://localhost:8404/stats -> node3 debe figurar DOWN"

echo ""
echo "======================================================"
echo " ESCENARIO C: recuperar db-node3"
echo "======================================================"
docker start db-node3
echo "Esperando resincronización..."
sleep 15
docker exec -u postgres db-node3 psql -c "SELECT pg_is_in_recovery();"
docker exec -u postgres db-node1 psql -c "SELECT client_addr, state, sync_state FROM pg_stat_replication;"

echo ""
echo "======================================================"
echo " ESCENARIO D: caída del nodo primario"
echo "======================================================"
docker stop db-node1
sleep 8
echo "Estado de HAProxy: revisar http://localhost:8404/stats (node1 DOWN)"
echo "Para completar el failover manual ejecutar:"
echo "   ./scripts/promote-replica.sh db-node2"
