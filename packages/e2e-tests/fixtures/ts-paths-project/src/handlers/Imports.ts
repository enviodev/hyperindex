// Mapped by tsconfig `paths`.
import { contractName } from "@lib/names";
// Resolved against tsconfig `baseUrl`.
import { eventName } from "src/lib/events";
// `paths` maps an installed package name, and like tsx the mapping wins.
import shadow from "postgres";
// A named export of a CommonJS module that re-exports through `require`, which
// Node resolves through the hooks to find the export.
import { flavor } from "../lib/cjs/index.js";

// Throwing stops `envio start` right after handlers load, with the imported
// values in the output.
throw new Error(`loaded ${contractName} ${eventName} ${shadow} ${flavor}`);
