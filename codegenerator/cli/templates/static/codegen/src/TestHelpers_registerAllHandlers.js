import { registerAllHandlers } from "./RegisterHandlers.bs.mjs";

await registerAllHandlers(); //Hack to allow top level await for test helpers
