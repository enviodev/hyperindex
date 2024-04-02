import log from "./imported-file";
var log2 = require("./imported-file-2");
import { log2 as log3 } from "./imported-file-2";

function handler() {
  console.log("I'm a handler");
  log();
  log2();
  log3();
}

handler();
