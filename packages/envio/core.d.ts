/**
 * Run the envio CLI with the given arguments (excluding the binary name).
 *
 * @example
 *   run(["codegen"])       // equivalent to `envio codegen`
 *   run(["dev"])           // equivalent to `envio dev`
 *   run(["init", "--help"])
 *
 * @throws {Error} If the CLI command fails.
 */
export declare function run(argv: string[]): void;
