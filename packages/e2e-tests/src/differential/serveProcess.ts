import { spawn, type ChildProcess } from "node:child_process";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import { servePort, serveUrl } from "./env.js";
import type { TrackOptions } from "./hasuraSetup.js";

export interface ServeProcess {
  child: ChildProcess;
  logs: string[];
}

const projectDir = fileURLToPath(
  new URL("../../../../scenarios/test_codegen/", import.meta.url)
);
// Resolved through the package dependency so CI (artifact install) and the
// local workspace link both work.
const envioBin = createRequire(import.meta.url).resolve("envio/bin.mjs");

export async function startServe(options: TrackOptions): Promise<ServeProcess> {
  const env: NodeJS.ProcessEnv = {
    ...process.env,
    ENVIO_SERVE_PORT: String(servePort),
  };
  if (options.responseLimit !== undefined) {
    env.ENVIO_HASURA_RESPONSE_LIMIT = String(options.responseLimit);
  } else {
    delete env.ENVIO_HASURA_RESPONSE_LIMIT;
  }
  if (options.aggregateEntities && options.aggregateEntities.length > 0) {
    env.ENVIO_HASURA_PUBLIC_AGGREGATE = JSON.stringify(
      options.aggregateEntities
    );
  } else {
    delete env.ENVIO_HASURA_PUBLIC_AGGREGATE;
  }

  const child = spawn(
    process.execPath,
    [envioBin, "serve", "--port", String(servePort)],
    { cwd: projectDir, env, stdio: ["ignore", "pipe", "pipe"] }
  );
  const logs: string[] = [];
  child.stdout?.on("data", (d) => logs.push(d.toString()));
  child.stderr?.on("data", (d) => logs.push(d.toString()));

  const deadline = Date.now() + 60_000;
  while (Date.now() < deadline) {
    if (child.exitCode !== null) {
      throw new Error(
        `envio serve exited with code ${child.exitCode}:\n${logs.join("")}`
      );
    }
    try {
      const res = await fetch(`${serveUrl}/healthz`);
      if (res.ok) return { child, logs };
    } catch {
      // not up yet
    }
    await new Promise((r) => setTimeout(r, 250));
  }
  child.kill("SIGKILL");
  throw new Error(`envio serve did not become healthy:\n${logs.join("")}`);
}

export async function stopServe(serve: ServeProcess | undefined): Promise<void> {
  if (!serve) return;
  if (serve.child.exitCode === null) {
    serve.child.kill("SIGTERM");
    await new Promise<void>((resolve) => {
      const t = setTimeout(() => {
        serve.child.kill("SIGKILL");
        resolve();
      }, 5000);
      serve.child.once("exit", () => {
        clearTimeout(t);
        resolve();
      });
    });
  }
}
