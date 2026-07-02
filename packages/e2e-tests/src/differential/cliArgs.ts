/**
 * Minimal `--flag` / `--name value` CLI argument parsing shared by the
 * differential scripts, so each script doesn't slice/index process.argv
 * itself.
 */
const argv = process.argv.slice(2);

export function arg(name: string): string | undefined {
  const i = argv.indexOf(name);
  return i >= 0 ? argv[i + 1] : undefined;
}

export function flag(name: string): boolean {
  return argv.includes(name);
}
