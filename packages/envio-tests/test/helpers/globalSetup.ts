import * as fs from "node:fs";
import * as path from "node:path";
import { fileURLToPath } from "node:url";

// `fromUserApi` keeps its generated modules for the whole run so vitest
// can render code frames from them. Clearing here — once, before any worker
// starts — is what stops them accumulating, without a worker ever deleting a
// sibling worker's files mid-run.
export default function setup(): void {
  const tmpDir = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", ".tmp");
  fs.rmSync(tmpDir, { recursive: true, force: true });
}
