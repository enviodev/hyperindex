export function runUpMigrations(
  persistence: any,
  config: any,
  shouldExit: boolean,
  reset?: boolean,
): Promise<number>;

export function runDownMigrations(
  persistence: any,
  shouldExit: boolean,
): Promise<number>;
