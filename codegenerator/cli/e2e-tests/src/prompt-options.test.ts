/**
 * Tests that verify the exact options displayed in each prompt.
 * These tests serve as documentation and regression tests for the CLI prompts.
 */
import { describe, it, expect, afterEach } from "vitest";
import { PtySession, createEnvioSession } from "./pty-helper.js";
import { normalizeOutput } from "./test-utils.js";

describe("Prompt Options Verification", () => {
  let session: PtySession | null = null;

  afterEach(() => {
    if (session) {
      session.kill();
      session = null;
    }
  });

  describe("Ecosystem options", () => {
    it("displays ecosystems in correct order: Evm, Svm, Fuel", async () => {
      session = await createEnvioSession(["init"]);

      await session.waitFor("Specify a folder name");
      await session.pressEnter();

      const output = await session.waitFor("Fuel"); // Wait for all options to appear
      const clean = normalizeOutput(output);
      const lines = clean.split("\n");

      // Find lines containing ecosystem options
      const evmLine = lines.findIndex((l) => l.includes("Evm"));
      const svmLine = lines.findIndex((l) => l.includes("Svm"));
      const fuelLine = lines.findIndex((l) => l.includes("Fuel"));

      expect(evmLine).toBeLessThan(svmLine);
      expect(svmLine).toBeLessThan(fuelLine);
    });
  });

  describe("EVM TypeScript options", () => {
    async function goToEvmOptions(): Promise<void> {
      if (!session) throw new Error("No session");
      await session.waitFor("Specify a folder name");
      await session.pressEnter();
      await session.waitFor("Choose blockchain ecosystem");
      await session.pressEnter(); // Select Evm
    }

    it("displays all 5 EVM options in correct order", async () => {
      session = await createEnvioSession(["init"]);
      await goToEvmOptions();

      const output = await session.waitFor("Feature: Factory Contract");
      const clean = normalizeOutput(output);

      // Verify all options are present
      expect(clean).toContain("From Address - Lookup ABI from block explorer");
      expect(clean).toContain("From ABI File - Use your own ABI file");
      expect(clean).toContain("Template: ERC20");
      expect(clean).toContain("Template: Greeter");
      expect(clean).toContain("Feature: Factory Contract");
    });

    it("displays options in expected order", async () => {
      session = await createEnvioSession(["init"]);
      await goToEvmOptions();

      const output = await session.waitFor("Feature: Factory Contract");
      const clean = normalizeOutput(output);
      const lines = clean.split("\n");

      // Find line indices
      const fromAddressIdx = lines.findIndex((l) =>
        l.includes("From Address - Lookup ABI")
      );
      const fromAbiIdx = lines.findIndex((l) => l.includes("From ABI File"));
      const erc20Idx = lines.findIndex((l) => l.includes("Template: ERC20"));
      const greeterIdx = lines.findIndex((l) =>
        l.includes("Template: Greeter")
      );
      const factoryIdx = lines.findIndex((l) =>
        l.includes("Feature: Factory Contract")
      );

      expect(fromAddressIdx).toBeLessThan(fromAbiIdx);
      expect(fromAbiIdx).toBeLessThan(erc20Idx);
      expect(erc20Idx).toBeLessThan(greeterIdx);
      expect(greeterIdx).toBeLessThan(factoryIdx);
    });
  });

  describe("EVM ReScript options", () => {
    async function goToEvmOptionsRescript(): Promise<void> {
      if (!session) throw new Error("No session");
      await session.waitFor("Specify a folder name");
      await session.pressEnter();
      await session.waitFor("Choose blockchain ecosystem");
      await session.pressEnter(); // Select Evm
    }

    it("only shows contract import options (no templates)", async () => {
      session = await createEnvioSession(["init", "--language", "rescript"]);
      await goToEvmOptionsRescript();

      const output = await session.waitFor("From ABI File");
      const clean = normalizeOutput(output);

      // Should have contract import options
      expect(clean).toContain("From Address");
      expect(clean).toContain("From ABI File");

      // Should NOT have templates
      expect(clean).not.toContain("Template: ERC20");
      expect(clean).not.toContain("Template: Greeter");
      expect(clean).not.toContain("Feature: Factory Contract");
    });
  });

  describe("Fuel options", () => {
    async function goToFuelOptions(): Promise<void> {
      if (!session) throw new Error("No session");
      await session.waitFor("Specify a folder name");
      await session.pressEnter();
      await session.waitFor("Choose blockchain ecosystem");
      await session.pressDown(); // Move past Evm
      await session.pressDown(); // Move to Fuel
      await session.pressEnter();
    }

    it("displays both Fuel options", async () => {
      session = await createEnvioSession(["init"]);
      await goToFuelOptions();

      const output = await session.waitFor("Template: Greeter");
      const clean = normalizeOutput(output);

      expect(clean).toContain("From ABI File - Use your own ABI file");
      expect(clean).toContain("Template: Greeter");
    });

    it("does not show block explorer option for Fuel", async () => {
      session = await createEnvioSession(["init"]);
      await goToFuelOptions();

      const output = await session.waitFor("Template: Greeter");
      const clean = normalizeOutput(output);

      expect(clean).not.toContain("From Address");
      expect(clean).not.toContain("block explorer");
    });
  });

  describe("API token options", () => {
    async function goToApiToken(): Promise<void> {
      if (!session) throw new Error("No session");
      await session.waitFor("Specify a folder name");
      await session.pressEnter();
      await session.waitFor("Choose blockchain ecosystem");
      await session.pressEnter(); // Evm
      await session.waitFor("Choose an initialization option");
      // Select Template: Greeter
      await session.pressDown();
      await session.pressDown();
      await session.pressDown();
      await session.pressEnter();
    }

    it("shows both API token options", async () => {
      session = await createEnvioSession(["init"]);
      await goToApiToken();

      const output = await session.waitFor("Add an existing API token");
      const clean = normalizeOutput(output);

      expect(clean).toContain("Create a new API token");
      expect(clean).toContain("Add an existing API token");
      expect(clean).toContain("envio.dev/app/api-tokens");
    });
  });
});
