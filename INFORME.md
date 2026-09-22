# Informe — Clúster de base de datos PostgreSQL sobre Docker

> Completar las tablas de la sección 9 y 10 con los valores reales obtenidos
> al ejecutar `scripts/benchmark.sh` y `scripts/test-failover.sh` en su
> equipo (los tiempos dependen del hardware usado).

## 1. Arquitectura propuesta

1 nodo primario (lectura/escritura) + 2 nodos secundarios (solo lectura),
replicación física de streaming asíncrona, HAProxy como proxy/balanceador y
punto único de acceso, con healthchecks en Node.js que reportan el rol de
cada nodo (`primary`/`replica`) para que HAProxy enrute correctamente.

## 2. Justificación tecnológica

Se eligió **PostgreSQL 16** con **replicación de streaming física** por ser
el mecanismo nativo, estable y de menor complejidad de configurar respecto a
alternativas como sharding lógico o replicación multi-máster, cumpliendo el
mínimo de 3 nodos exigido por la consigna. **HAProxy** se eligió por ser
liviano, soportar `httpchk` con verificación de contenido de respuesta (clave
para diferenciar primario/réplica) y exponer métricas Prometheus nativas.

## 3. Diseño de infraestructura

Ver diagrama y detalle de red/puertos/volúmenes en `README.md` (secciones 1,
6 y 7). Resumen:
- Red Docker `cluster-net` (bridge interno).
- Nodos: `db-node1` (primario), `db-node2`, `db-node3` (réplicas), resueltos
  por nombre de servicio Docker DNS.
- Persistencia: volúmenes Docker nombrados por nodo.
- Replicación: streaming WAL físico asíncrono, con slots de replicación
  dedicados por réplica.
- Balanceador: HAProxy, puertos 5000 (escritura) / 5001 (lectura).
- Monitorización: Prometheus + postgres-exporter (uno por nodo) + Grafana.

## 4-7. Implementación, configuración, seguridad, base de datos

Ver `docker-compose.yml`, `node1/init/01-init-primary.sh`,
`config/haproxy/haproxy.cfg` y sección 5-7 de `README.md`. La base de datos
de pruebas (`empresa`) se carga con `pgbench -i -s 10` (tabla `pgbench_accounts`
con ~1.000.000 de filas) para tener volumen representativo, además de la
tabla `clientes` usada por el cliente Node.js de demostración.

## 8. Pruebas funcionales

Verificación de que el cliente Node.js puede insertar (puerto 5000) y leer
(puerto 5001) correctamente, y que `pg_stat_replication` en el primario
muestra ambas réplicas en estado `streaming`.

## 9. Pruebas de rendimiento (pgbench)

| Clientes concurrentes | TPS (promedio 3 corridas) | Latencia promedio (ms) |
|------------------------|----------------------------|--------------------------|
| 10                      | _completar_                | _completar_              |
| 25                      | _completar_                | _completar_              |
| 50                      | _completar_                | _completar_              |
| 100                     | _completar_                | _completar_              |
| 200                     | _completar_                | _completar_              |

*(Valores obtenidos con `./scripts/benchmark.sh`, log completo en
`backups/benchmark_<fecha>.log`)*

## 10. Pruebas de fallos (escenarios A-D)

| Escenario | ¿Sistema sigue funcionando? | ¿Pérdida de consultas? | Latencia | Observaciones |
|-----------|------------------------------|---------------------------|----------|-----------------|
| A - todos OK | Sí | No | Base | Referencia |
| B - cae db-node3 | Sí | No (HAProxy redirige a db-node2) | Sube levemente | node3 pasa a DOWN en `/stats` en <10s |
| C - recupera db-node3 | Sí | No | Vuelve a la baseline | Resincroniza vía `pg_basebackup`/WAL, entra de nuevo a `pg_stat_replication` |
| D - cae db-node1 (primario) | Escrituras se detienen hasta promoción manual | Sí, las escrituras en vuelo sin ACK pueden perderse | N/A hasta promover | Requiere `promote-replica.sh`; no hay failover automático |

*(Completar con capturas/mediciones reales de `docker stats` y del panel de
Grafana durante la ejecución de `scripts/test-failover.sh`.)*

## 11. Pruebas de escalabilidad

| Nodos activos para lectura | Clientes | TPS | Latencia | CPU | RAM |
|------------------------------|----------|-----|----------|-----|-----|
| 1                              | 50       | _completar_ | _completar_ | _completar_ | _completar_ |
| 2                              | 50       | _completar_ | _completar_ | _completar_ | _completar_ |

> Con 3 nodos (1 primario + 2 réplicas) solo hay 2 nodos que puedan absorber
> lectura adicional; agregar más réplicas ayuda a escalar **lecturas**, no
> escrituras (el primario sigue siendo el único que escribe). El TPS de
> escritura está limitado por el disco/WAL del primario y por
> `synchronous_commit`, no por la cantidad de réplicas.

## 12. Monitorización

Dashboards en Grafana (datasource Prometheus autoprovisionado) mostrando:
conexiones activas, TPS/QPS (via `pg_stat_database`), lag de replicación
(`pg_stat_replication`), CPU/RAM/red de contenedores y estado de HAProxy
(`/stats` y métricas `/metrics`).

## 13-14. Resultados y análisis — respuestas a las preguntas obligatorias

1. **¿Escala horizontalmente?** Sí, para lecturas (agregar réplicas
   incrementa la capacidad de lectura); no para escrituras (solo hay un
   primario).
2. **¿Qué sucede al agregar un nodo?** Se suma capacidad de lectura y
   redundancia; no mejora el throughput de escritura y agrega carga de WAL
   al primario (un `wal sender` más).
3. **¿Existe punto de saturación?** Sí: al aumentar la concurrencia el TPS
   deja de crecer linealmente y la latencia empieza a subir (ver tabla de
   la sección 9) cuando se agota `max_connections`, CPU o I/O del primario.
4. **Cuello de botella principal:** típicamente I/O de disco / WAL del nodo
   primario, o CPU si el volumen de datos cabe en caché (`shared_buffers`).
5. **¿La replicación afecta el rendimiento?** Sí, levemente: cada
   transacción en el primario debe generar y enviar WAL a 2 réplicas
   (más overhead de CPU/red), aunque al ser asíncrona no espera el ACK.
6. **¿Qué ocurre al fallar un nodo?** Si es secundario: HAProxy deja de
   enviarle tráfico de lectura, el resto sigue funcionando. Si es el
   primario: se detienen las escrituras hasta un failover manual.
7. **¿Pérdida de datos?** Posible, limitada a transacciones confirmadas en
   el primario pero no replicadas aún (ventana de replication lag), por
   usar replicación asíncrona.
8. **Tiempo de recuperación:** de un nodo secundario, segundos (reinicio +
   reconexión de streaming); del primario, depende del tiempo que tarde el
   operador en ejecutar `promote-replica.sh` (manual).
9. **¿Qué pasa con las conexiones existentes?** Las conexiones abiertas al
   nodo caído se cortan; el cliente debe reconectar (el pool `pg` de
   Node.js reintenta automáticamente contra HAProxy).
10. **Comportamiento con mayor concurrencia:** el TPS crece hasta cierto
    punto y luego se aplana o cae mientras la latencia aumenta (saturación
    de conexiones/CPU/disco).
11. **¿Garantiza alta disponibilidad?** Para lecturas, sí (dos réplicas).
    Para escrituras, alta disponibilidad parcial: sobrevive a la caída de
    réplicas, pero no del primario sin intervención manual.
12. **Puntos únicos de falla:** el nodo primario (para escrituras) y
    HAProxy (único balanceador, sin réplica del proxy en este laboratorio).
13. **¿Si falla el balanceador?** El cliente pierde el punto de acceso al
    clúster completo (ni lecturas ni escrituras), aunque los nodos de base
    de datos sigan sanos. Mitigación en producción: HAProxy redundante +
    IP virtual (keepalived) o un balanceador gestionado.
14. **¿Si falla el almacenamiento?** Se pierde el volumen del nodo afectado;
    si es el primario y no hay backup/réplica al día, hay pérdida de datos.
    Los volúmenes Docker no están replicados entre sí en este diseño.
15. **¿Apta para producción?** No tal cual: falta failover automático,
    balanceador redundante, backups automatizados y cifrado en tránsito
    (TLS), entre otros.
16. **Cambios necesarios para producción:** failover automático (Patroni,
    repmgr o Postgres con `pg_auto_failover`), TLS en las conexiones,
    HAProxy en alta disponibilidad, backups automatizados con retención
    (WAL-G/pgBackRest), alertas en Grafana, y separación en distintos hosts
    físicos/zonas de disponibilidad reales.

## 15. Limitaciones

Ver sección 13 de `README.md`.
