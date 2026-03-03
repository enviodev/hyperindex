import { describe, it, expect } from "vitest";
import { ensureExecutable } from "./config.js";
import fs from "fs";
import path from "path";
import os from "os";

describe("ensureExecutable", () => {
  it("makes a non-executable file executable", () => {
    const tmp = path.join(os.tmpdir(), `test-bin-${Date.now()}`);
    fs.writeFileSync(tmp, "#!/bin/sh\necho hi\n", { mode: 0o644 });

    // Verify not executable
    expect(() => fs.accessSync(tmp, fs.constants.X_OK)).toThrow();

    ensureExecutable(tmp);

    // Now it should be executable
    fs.accessSync(tmp, fs.constants.X_OK);
    fs.unlinkSync(tmp);
  });

  it("leaves an already-executable file unchanged", () => {
    const tmp = path.join(os.tmpdir(), `test-bin-${Date.now()}`);
    fs.writeFileSync(tmp, "#!/bin/sh\necho hi\n", { mode: 0o755 });

    ensureExecutable(tmp);

    fs.accessSync(tmp, fs.constants.X_OK);
    fs.unlinkSync(tmp);
  });
});
