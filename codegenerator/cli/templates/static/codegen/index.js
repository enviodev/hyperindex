/**
 This file serves as an entry point when referencing generated as a node module
 */

const handlers = require("./src/Handlers.res.js");
const TestHelpers = require("./src/TestHelpers.res.js");
const BigDecimal = require("bignumber.js");

module.exports = {
  ...handlers,
  BigDecimal,
  TestHelpers,
};
