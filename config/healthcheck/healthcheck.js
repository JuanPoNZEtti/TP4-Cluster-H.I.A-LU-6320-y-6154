// Servicio HTTP en Node.js que consulta pg_is_in_recovery() en un nodo
// PostgreSQL y expone el resultado como texto plano ("primary" / "replica").
// HAProxy usa esta respuesta (http-check expect string) para decidir
// a qué nodo enrutar las escrituras y las lecturas.
const http = require('http');
const { Client } = require('pg');

const DB_HOST = process.env.DB_HOST;
const DB_PORT = process.env.DB_PORT || 5432;
const DB_USER = process.env.DB_USER;
const DB_PASSWORD = process.env.DB_PASSWORD;
const DB_NAME = process.env.DB_NAME || 'postgres';
const PORT = process.env.PORT || 8008;

async function checkRole() {
  const client = new Client({
    host: DB_HOST,
    port: DB_PORT,
    user: DB_USER,
    password: DB_PASSWORD,
    database: DB_NAME,
    connectionTimeoutMillis: 2000,
    query_timeout: 2000,
  });

  await client.connect();
  try {
    const res = await client.query('SELECT pg_is_in_recovery() AS in_recovery;');
    return res.rows[0].in_recovery ? 'replica' : 'primary';
  } finally {
    await client.end();
  }
}

const server = http.createServer(async (req, res) => {
  try {
    const role = await checkRole();
    res.writeHead(200, { 'Content-Type': 'text/plain' });
    res.end(role);
  } catch (err) {
    console.error(`[healthcheck:${DB_HOST}] error:`, err.message);
    res.writeHead(503, { 'Content-Type': 'text/plain' });
    res.end('down');
  }
});

server.listen(PORT, () => {
  console.log(`Healthcheck de ${DB_HOST} escuchando en el puerto ${PORT}`);
});
