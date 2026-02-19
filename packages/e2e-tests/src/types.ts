/**
 * Command execution result
 */
export interface CommandResult {
  exitCode: number;
  stdout: string;
  stderr: string;
}

/**
 * GraphQL validation function
 */
export type GraphQLValidation<T = unknown> = (data: T) => boolean;
