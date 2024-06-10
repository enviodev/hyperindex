/**
 This file serves as an entry point when referencing generated as a node module
 */

const handlers = require("./src/Handlers.bs");
const TestHelpers = require("./src/TestHelpers.bs");
const BigDecimal = require("bignumber.js");

module.exports = {
  ...handlers,
  BigDecimal,
  TestHelpers,
};
