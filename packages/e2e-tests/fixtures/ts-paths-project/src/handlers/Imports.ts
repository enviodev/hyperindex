// Mapped by tsconfig `paths`.
import { contractName } from "@lib/names";
// Resolved against tsconfig `baseUrl`.
import { eventName } from "src/lib/events";
// `paths` maps an installed package name, and like tsx the mapping wins.
import shadow from "postgres";

// Throwing stops `envio start` right after handlers load, with the imported
// values in the output.
throw new Error(`loaded ${contractName} ${eventName} ${shadow}`);
