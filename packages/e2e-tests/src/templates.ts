/**
 * Template generation using envio CLI
 */

import fs from "fs/promises";
import path from "path";
import { runCommand } from "./utils/process.js";
import { Ecosystem, Template } from "./types.js";

export interface TemplateConfig {
  ecosystem: Ecosystem;
  template: Template;
  language: "TypeScript";
}

export interface GeneratorOptions {
  /** Output directory for generated templates */
  outputDir: string;
  /** Path to envio CLI binary */
  envioBin?: string;
  /** API token for envio */
  apiToken?: string;
}

/**
 * All template combinations to test
 */
export const ALL_TEMPLATES: TemplateConfig[] = [
  { ecosystem: "evm", template: "Erc20", language: "TypeScript" },
  { ecosystem: "evm", template: "Greeter", language: "TypeScript" },
  { ecosystem: "fuel", template: "Greeter", language: "TypeScript" },
];

/**
 * Generate a single template
 */
export async function generateTemplate(
  config: TemplateConfig,
  options: GeneratorOptions
): Promise<string> {
  const templateDir = path.join(
    options.outputDir,
    `${config.ecosystem}_${config.template}`,
    config.language
  );

  // Clear existing directory if it exists
  try {
    await fs.rm(templateDir, { recursive: true, force: true });
  } catch {
    // Directory may not exist
  }

  await fs.mkdir(templateDir, { recursive: true });

  const envioBin = options.envioBin ?? "envio";
  const args = buildInitArgs(config, templateDir, options.apiToken);

  console.log(`Generating template: ${config.ecosystem}_${config.template}`);

  const result = await runCommand(envioBin, args, {
    cwd: templateDir,
    timeout: 120000,
    env: options.apiToken ? { ENVIO_API_TOKEN: options.apiToken } : undefined,
  });

  if (result.exitCode !== 0) {
    throw new Error(
      `Failed to generate template ${config.ecosystem}_${config.template}: ${result.stderr}`
    );
  }

  return templateDir;
}

/**
 * Generate all templates
 */
export async function generateAllTemplates(
  options: GeneratorOptions
): Promise<Map<string, string>> {
  const results = new Map<string, string>();

  for (const config of ALL_TEMPLATES) {
    const dir = await generateTemplate(config, options);
    results.set(`${config.ecosystem}_${config.template}`, dir);
  }

  return results;
}

function buildInitArgs(
  config: TemplateConfig,
  directory: string,
  apiToken?: string
): string[] {
  const args = [
    "init",
    "--name",
    "test",
    "--language",
    config.language,
    "--directory",
    directory,
  ];

  if (apiToken) {
    args.push("--api-token", apiToken);
  }

  if (config.ecosystem === "evm") {
    args.push("template", "--template", config.template);
  } else if (config.ecosystem === "fuel") {
    args.push("fuel", "template", "--template", config.template);
  }

  return args;
}

/**
 * Copy custom test indexers to output directory
 */
export async function copyTestIndexers(
  sourceDir: string,
  outputDir: string
): Promise<void> {
  const testIndexersSource = path.join(sourceDir, "test_indexers");
  const testIndexersDest = path.join(outputDir, "test_indexers");

  try {
    await fs.cp(testIndexersSource, testIndexersDest, { recursive: true });
    console.log("Copied test indexers to output directory");
  } catch (err) {
    console.warn("Could not copy test indexers:", err);
  }
}
