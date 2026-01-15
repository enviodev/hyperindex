// This file registers tsx for TypeScript handler support at runtime
import { register } from "node:module";
import { pathToFileURL } from "node:url";

register("tsx/esm", pathToFileURL("./"));
