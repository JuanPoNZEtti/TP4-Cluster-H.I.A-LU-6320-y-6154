// Cliente Node.js del clúster de base de datos.
// Se conecta EXCLUSIVAMENTE a HAProxy (el punto único de acceso), nunca
// directamente a un nodo: puerto 5000 para escrituras (primario) y
// puerto 5001 para lecturas (réplicas, balanceadas en round-robin).
const { Pool } = require('pg');

const base = {
  user: process.env.APP_USER || 'aplicacion',
  password: process.env.APP_PASSWORD,
  database: process.env.DB_NAME || 'empresa',
  connectionTimeoutMillis: 5000,
};

const writePool = new Pool({
  ...base,
  host: process.env.LB_HOST || 'haproxy',
  port: process.env.WRITE_PORT || 5000,
  max: 10,
});

const readPool = new Pool({
  ...base,
  host: process.env.LB_HOST || 'haproxy',
  port: process.env.READ_PORT || 5001,
  max: 10,
});

async function setup() {
  await writePool.query(`
    CREATE TABLE IF NOT EXISTS clientes (
      id SERIAL PRIMARY KEY,
      nombre TEXT NOT NULL,
      email TEXT NOT NULL,
      creado_en TIMESTAMP DEFAULT now()
    );
  `);
  console.log('[setup] Tabla "clientes" lista.');
}

async function insertarCliente(nombre, email) {
  const res = await writePool.query(
    'INSERT INTO clientes (nombre, email) VALUES ($1, $2) RETURNING id;',
    [nombre, email]
  );
  console.log(`[escritura] OK id=${res.rows[0].id} (puerto 5000 -> nodo primario)`);
}

async function listarClientes() {
  const res = await readPool.query(
    'SELECT id, nombre, email, creado_en FROM clientes ORDER BY id DESC LIMIT 5;'
  );
  console.log(`[lectura] OK ${res.rowCount} filas (puerto 5001 -> réplica)`);
  console.table(res.rows);
}

async function loop() {
  await setup();
  let i = 0;
  setInterval(async () => {
    i++;
    try {
      await insertarCliente(`Cliente_${i}`, `cliente${i}@demo.com`);
      await listarClientes();
    } catch (err) {
      console.error('[error]', err.message);
    }
  }, 5000);
}

loop();
