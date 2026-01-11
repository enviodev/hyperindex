import { describe, it, expect, beforeAll, afterAll, afterEach } from "vitest";
import {
  PtySession,
  createEnvioSession,
} from "./pty-helper.js";
import {
  createTempDir,
  cleanupTempDir,
  normalizeOutput,
} from "./test-utils.js";

describe("envio init", () => {
  let tempDir: string;
  let session: PtySession | null = null;

  beforeAll(() => {
    tempDir = createTempDir();
  });

  afterAll(() => {
    cleanupTempDir(tempDir);
  });

  afterEach(() => {
    if (session) {
      session.kill();
      session = null;
    }
  });

  async function startInit(): Promise<PtySession> {
    session = await createEnvioSession(["init"]);
    return session;
  }

  describe("folder name prompt", () => {
    it("shows folder name prompt with correct default", async () => {
      session = await startInit();

      const output = await session.waitFor("Specify a folder name");
      const clean = normalizeOutput(output);

      expect(clean).toContain("Specify a folder name");
      expect(clean).toContain("ENTER to skip");
    });

    it("accepts custom folder name", async () => {
      session = await startInit();

      await session.waitFor("Specify a folder name");
      await session.type("my-indexer");
      await session.pressEnter();

      // Should proceed to ecosystem selection
      const output = await session.waitFor("Choose blockchain ecosystem");
      expect(output).toContain("Choose blockchain ecosystem");
    });

    it("accepts default folder name with Enter", async () => {
      session = await startInit();

      await session.waitFor("Specify a folder name");
      await session.pressEnter();

      // Should proceed to ecosystem selection
      const output = await session.waitFor("Choose blockchain ecosystem");
      expect(output).toContain("Choose blockchain ecosystem");
    });
  });

  describe("ecosystem selection", () => {
    it("shows all three ecosystems: Evm, Svm, Fuel", async () => {
      session = await startInit();

      await session.waitFor("Specify a folder name");
      await session.pressEnter();

      const output = await session.waitFor("Choose blockchain ecosystem");
      const clean = normalizeOutput(output);

      expect(clean).toContain("Evm");
      expect(clean).toContain("Svm");
      expect(clean).toContain("Fuel");
    });

    it("Evm is the first/default option", async () => {
      session = await startInit();

      await session.waitFor("Specify a folder name");
      await session.pressEnter();

      const output = await session.waitFor("Choose blockchain ecosystem");

      // First option should be Evm (indicated by selection marker)
      const lines = normalizeOutput(output).split("\n");
      const evmLine = lines.find((l) => l.includes("Evm"));
      expect(evmLine).toBeDefined();
    });
  });

  describe("EVM initialization options", () => {
    async function selectEvm(): Promise<void> {
      if (!session) throw new Error("No session");

      await session.waitFor("Specify a folder name");
      await session.pressEnter();

      await session.waitFor("Choose blockchain ecosystem");
      await session.pressEnter(); // Select Evm (first option)
    }

    it("shows all EVM init options for TypeScript", async () => {
      session = await startInit();
      await selectEvm();

      const output = await session.waitFor("Choose an initialization option");
      const clean = normalizeOutput(output);

      // Contract import options
      expect(clean).toContain("From Address - Lookup ABI from block explorer");
      expect(clean).toContain("From ABI File - Use your own ABI file");

      // Templates
      expect(clean).toContain("Template: ERC20");
      expect(clean).toContain("Template: Greeter");

      // Features
      expect(clean).toContain("Feature: Factory Contract");
    });

    it("From Address option is first/default", async () => {
      session = await startInit();
      await selectEvm();

      const output = await session.waitFor("Choose an initialization option");
      const clean = normalizeOutput(output);

      // First non-empty line after prompt should be "From Address"
      const lines = clean.split("\n").filter((l) => l.trim());
      const fromAddressIndex = lines.findIndex((l) =>
        l.includes("From Address")
      );
      expect(fromAddressIndex).toBeGreaterThan(-1);
    });
  });

  describe("Fuel initialization options", () => {
    async function selectFuel(): Promise<void> {
      if (!session) throw new Error("No session");

      await session.waitFor("Specify a folder name");
      await session.pressEnter();

      await session.waitFor("Choose blockchain ecosystem");
      await session.pressDown(); // Move past Evm
      await session.pressDown(); // Move to Fuel (after Svm)
      await session.pressEnter();
    }

    it("shows Fuel init options", async () => {
      session = await startInit();
      await selectFuel();

      const output = await session.waitFor("Choose an initialization option");
      const clean = normalizeOutput(output);

      expect(clean).toContain("From ABI File");
      expect(clean).toContain("Template: Greeter");
    });
  });

  describe("SVM initialization", () => {
    async function selectSvm(): Promise<void> {
      if (!session) throw new Error("No session");

      await session.waitFor("Specify a folder name");
      await session.pressEnter();

      await session.waitFor("Choose blockchain ecosystem");
      await session.pressDown(); // Move to Svm
      await session.pressEnter();
    }

    it("skips option selection for SVM and proceeds to project generation", async () => {
      session = await startInit();
      await selectSvm();

      // SVM only has one template, so it skips option selection.
      // SVM doesn't use HyperSync, so it also skips the API token prompt.
      // It should proceed directly to project generation.
      const output = await session.waitFor("Project template ready", {
        timeout: 30000,
      });
      expect(output).toContain("Project template ready");
    });
  });

  describe("API token prompt", () => {
    async function goToApiTokenPrompt(): Promise<void> {
      if (!session) throw new Error("No session");

      await session.waitFor("Specify a folder name");
      await session.pressEnter();

      await session.waitFor("Choose blockchain ecosystem");
      await session.pressEnter(); // Select Evm

      await session.waitFor("Choose an initialization option");
      // Select Template: Greeter (4th option: 0=From Address, 1=From ABI, 2=ERC20, 3=Greeter)
      await session.pressDown();
      await session.pressDown();
      await session.pressDown();
      await session.pressEnter();
    }

    it("shows API token options", async () => {
      session = await startInit();
      await goToApiTokenPrompt();

      const output = await session.waitFor("Add an API token");
      const clean = normalizeOutput(output);

      expect(clean).toContain("Create a new API token");
      expect(clean).toContain("Add an existing API token");
    });
  });
});

describe("envio init with language flag", () => {
  let tempDir: string;
  let session: PtySession | null = null;

  beforeAll(() => {
    tempDir = createTempDir();
  });

  afterAll(() => {
    cleanupTempDir(tempDir);
  });

  afterEach(() => {
    if (session) {
      session.kill();
      session = null;
    }
  });

  it("--language rescript limits EVM options to contract import only", async () => {
    session = await createEnvioSession(["init", "--language", "rescript"]);

    await session.waitFor("Specify a folder name");
    await session.pressEnter();

    await session.waitFor("Choose blockchain ecosystem");
    await session.pressEnter(); // Select Evm

    const output = await session.waitFor("Choose an initialization option");
    const clean = normalizeOutput(output);

    // Should have contract import options
    expect(clean).toContain("From Address");
    expect(clean).toContain("From ABI File");

    // Should NOT have templates (ReScript doesn't support them)
    expect(clean).not.toContain("Template: ERC20");
    expect(clean).not.toContain("Template: Greeter");
    expect(clean).not.toContain("Feature: Factory Contract");
  });

  it("--language rescript with SVM shows TypeScript override message", async () => {
    session = await createEnvioSession(["init", "--language", "rescript"]);

    await session.waitFor("Specify a folder name");
    await session.pressEnter();

    await session.waitFor("Choose blockchain ecosystem");
    await session.pressDown(); // Move to Svm
    await session.pressEnter();

    // Should show message about TypeScript override
    const output = await session.waitFor("TypeScript");
    expect(output).toContain("SVM templates are only available in TypeScript");
  });
});
