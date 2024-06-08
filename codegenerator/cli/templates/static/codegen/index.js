/**
 This file serves as an entry point when referencing generated as a node module
 */

const handlers = require("./src/Handlers.bs");
const TestHelpers = require("./src/TestHelpers.bs");
const { BigDecimalTypescript } = require("./src/bindings/BigDecimal.bs");

module.exports = {
  ...handlers,
  BigDecimal: BigDecimalTypescript,
  TestHelpers,
};
