// Mapped by tsconfig `paths`.
import { contractName } from "@lib/names";
// Resolved against tsconfig `baseUrl`.
import { eventName } from "src/lib/events";
// `paths` maps an installed package name, and like tsx the mapping wins.
import shadow from "postgres";
// A named export of a CommonJS module that re-exports through `require`, which
// Node has to resolve while the hooks are registered.
import { flavor } from "../lib/cjs/index.js";
// A dependency importing `./value.js` next to a `value.ts` gets the `.js`, as
// it would without the hooks.
import { origin } from "fake-dep";

// Throwing stops `envio start` right after handlers load, with the imported
// values in the output.
throw new Error(`loaded ${contractName} ${eventName} ${shadow} ${flavor} ${origin}`);
