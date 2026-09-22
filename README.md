# Cluster-db — Clúster de PostgreSQL sobre Docker

Clúster de base de datos con 1 nodo primario + 2 nodos secundarios (réplicas de
streaming asíncronas), proxy/balanceador HAProxy, monitorización con
Prometheus + Grafana y cliente de acceso en Node.js.

## 1. Arquitectura

```
                         ┌─────────────┐
                         │   Cliente    │  (Node.js)
                         └──────┬──────┘
                                │  :5000 escritura / :5001 lectura
                         ┌──────▼──────┐
                         │   HAProxy    │  (punto único de acceso)
                         └───┬───┬───┬─┘
             ┌───────────────┘   │   └───────────────┐
             ▼                   ▼                   ▼
      ┌─────────────┐    ┌─────────────┐     ┌─────────────┐
      │  db-node1   │───►│  db-node2   │     │  db-node3   │
      │  PRIMARIO   │    │ SECUNDARIO  │     │ SECUNDARIO  │
      │             │───────────────────────►│             │
      └─────────────┘  streaming replication └─────────────┘
      (replicación física asíncrona, streaming WAL)
```

Cada nodo de base de datos lleva un **sidecar Node.js** (`healthcheck`) que
consulta `pg_is_in_recovery()` y expone `http://nodo:8008` devolviendo
`primary` o `replica`. HAProxy usa esa respuesta para saber en todo momento
a qué nodo enviar escrituras (puerto 5000) y a cuáles enviar lecturas
(puerto 5001, round-robin entre réplicas). Si se promueve manualmente una
réplica, HAProxy la detecta sola en el siguiente healthcheck (cada 3s).

## 2. Por qué esta arquitectura

- **Problema que resuelve:** un único servidor de base de datos es un punto
  único de falla y no permite escalar lecturas.
- **Ventajas:** alta disponibilidad de lectura (2 réplicas), escalado
  horizontal de lecturas, recuperación ante falla de un nodo secundario sin
  intervención, backups sin afectar al primario.
- **Desventajas:** la replicación es asíncrona (`synchronous_commit=off`),
  por lo que puede haber pérdida de las últimas transacciones si el primario
  cae abruptamente (replication lag). El failover del nodo **primario** no es
  automático: requiere ejecutar `promote-replica.sh` (no se usa
  Patroni/repmgr para mantener la solución simple).
- **Qué ocurre si falla un nodo secundario:** HAProxy dejar de enviarle
  tráfico de lectura (queda `DOWN` en el healthcheck) y las lecturas se
  concentran en la réplica restante; no hay pérdida de escrituras.
- **Distribución de lecturas/escrituras:** escrituras siempre van al puerto
  5000 (solo el primario pasa el check `expect string primary`); lecturas al
  puerto 5001, balanceadas round-robin entre los nodos que responden
  `replica`.
- **Consistencia:** eventual/asíncrona entre primario y réplicas (replication
  lag típicamente de milisegundos en LAN/localhost). Las lecturas en réplica
  pueden no reflejar instantáneamente la última escritura.

## 3. Estructura del proyecto

```
Cluster-db/
├── docker-compose.yml
├── .env                      # credenciales y parámetros (NO subir a git)
├── node1/init/               # script de init del primario (usuarios, pg_hba)
├── node2/, node3/             # Dockerfile + entrypoint de clonado (réplicas)
├── config/
│   ├── haproxy/haproxy.cfg
│   ├── healthcheck/           # servicio Node.js de rol primary/replica
│   ├── prometheus/prometheus.yml
│   └── grafana/provisioning/
├── scripts/
│   ├── replica-entrypoint.sh
│   ├── promote-replica.sh     # failover manual
│   ├── test-failover.sh       # automatiza escenarios A-D
│   ├── benchmark.sh           # pgbench con varias concurrencias
│   └── backup.sh
├── backups/
├── monitoring/
├── client/                    # cliente Node.js (vía HAProxy)
└── README.md
```

## 4. Imagen y versión del motor

- **Motor:** PostgreSQL 16 (`postgres:16`, imagen oficial de Docker Hub).
- **Proxy:** `haproxy:2.9-alpine`.
- **Monitorización:** `prom/prometheus`, `grafana/grafana`,
  `prometheuscommunity/postgres-exporter`.
- **Healthcheck y cliente:** `node:20-alpine`.

## 5. Usuarios y permisos

| Usuario           | Rol                                   | Permisos                              |
|-------------------|----------------------------------------|----------------------------------------|
| `admin_cluster`   | Superusuario (reemplaza a `postgres`) | Administración completa                |
| `replicacion`     | Replicación                           | Solo `REPLICATION`, sin acceso a datos |
| `aplicacion`      | Aplicación                            | Lectura/escritura sobre `empresa`      |
| `monitorizacion`  | Monitorización                        | Rol `pg_monitor` (solo lectura de métricas) |

No se usa `root` ni `postgres` como usuario de la aplicación. Las
contraseñas se definen en `.env` (variables de entorno), nunca en el código.

## 6. Redes, volúmenes y puertos

- **Red:** `cluster-net` (bridge, interna a Docker Compose).
- **Volúmenes:** `node1-data`, `node2-data`, `node3-data` (persistencia),
  `prometheus-data`, `grafana-data`.
- **Puertos publicados al host:**
  | Puerto | Servicio                              |
  |--------|-----------------------------------------|
  | 5000   | HAProxy → escritura (primario)          |
  | 5001   | HAProxy → lectura (réplicas)            |
  | 8404   | Panel de estadísticas de HAProxy        |
  | 8405   | Métricas Prometheus de HAProxy          |
  | 9090   | Prometheus                              |
  | 3000   | Grafana                                 |

  Los puertos 5432 de cada nodo **no se publican al host**: solo son
  accesibles dentro de `cluster-net`. Justificación: el cliente y cualquier
  acceso externo deben pasar siempre por HAProxy (punto único de acceso);
  exponer 5432 de cada nodo permitiría saltarse el balanceador y el control
  de roles primario/réplica.

## 7. Parámetros de replicación y rendimiento

- `wal_level=replica`, `max_wal_senders=10`, `max_replication_slots=10`,
  `hot_standby=on`, `synchronous_commit=off` (replicación asíncrona, prioriza
  rendimiento de escritura sobre consistencia estricta).
- `shared_buffers=256MB`, `max_connections=200`.
- Réplicas creadas con `pg_basebackup -R -C -S slot_<nodo>`: crean
  automáticamente `standby.signal`, `primary_conninfo` y un slot de
  replicación físico dedicado por nodo (evita que el primario purgue WAL
  necesario para una réplica caída).

## 8. Cómo levantar el clúster

```bash
cd Cluster-db
docker compose up -d --build
docker compose ps
docker exec -u postgres db-node1 psql -c "SELECT client_addr, state, sync_state FROM pg_stat_replication;"
```

Grafana: http://localhost:3000 (usuario `admin`, contraseña en `.env`).
Prometheus: http://localhost:9090
Stats HAProxy: http://localhost:8404/stats

## 9. Pruebas de operatividad (A-D)

```bash
chmod +x scripts/*.sh
./scripts/test-failover.sh          # ejecuta A, B, C y D en secuencia
./scripts/promote-replica.sh db-node2   # completa el failover del escenario D
```

## 10. Benchmark de rendimiento

```bash
./scripts/benchmark.sh
```
Ejecuta `pgbench` con 10/25/50/100/200 clientes concurrentes, 3 corridas por
nivel, 30s cada corrida. Resultados en `backups/benchmark_<fecha>.log`.

## 11. Cliente de acceso

El servicio `client` (Node.js) se conecta únicamente a HAProxy y hace
inserciones (puerto 5000) y lecturas (puerto 5001) cada 5s:
```bash
docker logs -f cluster-client
```

## 12. Seguridad — resumen

- Usuario superusuario renombrado (no `postgres`).
- 4 roles diferenciados con permisos mínimos necesarios.
- Contraseñas en `.env`, no hardcodeadas.
- `pg_hba.conf` restringido a la subred interna de Docker.
- Puerto 5432 de los nodos no expuesto al host.

## 13. Limitaciones conocidas

- El failover del primario es manual (sin Patroni/repmgr/etcd).
- Replicación asíncrona: posible pérdida de las últimas transacciones ante
  una caída abrupta del primario.
- Un único host físico: no evalúa fallos de red reales entre datacenters.
- HAProxy es en sí mismo un punto único de falla (mitigable en producción
  con keepalived + IP virtual, fuera del alcance de este laboratorio).
