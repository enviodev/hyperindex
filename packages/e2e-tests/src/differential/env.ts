export const hasuraPort = Number(process.env.HASURA_EXTERNAL_PORT ?? 8080);
export const servePort = Number(process.env.ENVIO_SERVE_PORT ?? 8081);
export const adminSecret = process.env.HASURA_GRAPHQL_ADMIN_SECRET ?? "testing";

export const hasuraUrl = `http://localhost:${hasuraPort}`;
export const serveUrl = `http://localhost:${servePort}`;

export const pgSchema = process.env.ENVIO_PG_SCHEMA ?? "public";

export const pg = {
  host: process.env.ENVIO_PG_HOST ?? "localhost",
  port: Number(process.env.ENVIO_PG_PORT ?? 5433),
  user: process.env.ENVIO_PG_USER ?? "postgres",
  password: process.env.ENVIO_PG_PASSWORD ?? "testing",
  database: process.env.ENVIO_PG_DATABASE ?? "envio-dev",
};

export const pgConnectionString = `postgres://${pg.user}:${encodeURIComponent(
  pg.password
)}@${pg.host}:${pg.port}/${pg.database}`;
