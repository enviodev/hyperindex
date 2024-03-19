import log from "./imported-file";
var log2 = require("./imported-file-2"); // hmm this isnt picked up, which means it needs to check multiple js versions
// import log2 from "./imported-file-2";

function handler() {
  console.log("I'm a handler");
  log();
}
