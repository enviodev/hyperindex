// Minimal Vitest bindings for ReScript

// Expectation object returned by expect()
type rec expectation<'a> = {
  // Equality matchers
  toBe: 'a => unit,
  toEqual: 'a => unit,
  toStrictEqual: 'a => unit,
  // Truthiness matchers
  toBeTruthy: unit => unit,
  toBeFalsy: unit => unit,
  toBeNull: unit => unit,
  toBeUndefined: unit => unit,
  toBeDefined: unit => unit,
  // Number matchers
  toBeGreaterThan: 'a => unit,
  toBeGreaterThanOrEqual: 'a => unit,
  toBeLessThan: 'a => unit,
  toBeLessThanOrEqual: 'a => unit,
  toBeCloseTo: (float, ~numDigits: int=?) => unit,
  toBeNaN: unit => unit,
  // String matchers
  toContain: string => unit,
  toMatch: RegExp.t => unit,
  toMatchString: string => unit,
  // Array matchers
  toContainItem: 'a => unit,
  toHaveLength: int => unit,
  // Object matchers
  toHaveProperty: string => unit,
  toHavePropertyValue: 'b. (string, 'b) => unit,
  // Exception matchers
  toThrow: unit => unit,
  toThrowError: string => unit,
  // Negation
  not: expectation<'a>,
}

// Test context passed to test callbacks
type testContext = {expect: 'a. ('a, ~message: string=?) => expectation<'a>}

// ============================================================================
// Test Suite Functions
// ============================================================================

@module("vitest")
external describe: (string, unit => unit) => unit = "describe"

@module("vitest") @scope("describe")
external describe_only: (string, unit => unit) => unit = "only"

@module("vitest") @scope("describe")
external describe_skip: (string, unit => unit) => unit = "skip"

// ============================================================================
// Test Functions (sync)
// ============================================================================

@module("vitest")
external it: (string, unit => unit) => unit = "it"

@module("vitest") @scope("it")
external it_only: (string, unit => unit) => unit = "only"

@module("vitest") @scope("it")
external it_skip: (string, unit => unit) => unit = "skip"

@module("vitest")
external test: (string, unit => unit) => unit = "test"

@module("vitest") @scope("test")
external test_only: (string, unit => unit) => unit = "only"

@module("vitest") @scope("test")
external test_skip: (string, unit => unit) => unit = "skip"

// ============================================================================
// Setup and Teardown
// ============================================================================

@module("vitest")
external beforeAll: (unit => unit) => unit = "beforeAll"

@module("vitest")
external afterAll: (unit => unit) => unit = "afterAll"

@module("vitest")
external beforeEach: (unit => unit) => unit = "beforeEach"

@module("vitest")
external afterEach: (unit => unit) => unit = "afterEach"

// ============================================================================
// Async Module
// ============================================================================

module Async = {
  @module("vitest")
  external it: (string, testContext => promise<unit>) => unit = "it"

  @module("vitest") @scope("it")
  external it_only: (string, testContext => promise<unit>) => unit = "only"

  @module("vitest") @scope("it")
  external it_skip: (string, testContext => promise<unit>) => unit = "skip"

  @module("vitest")
  external test: (string, testContext => promise<unit>) => unit = "test"

  @module("vitest") @scope("test")
  external test_only: (string, testContext => promise<unit>) => unit = "only"

  @module("vitest") @scope("test")
  external test_skip: (string, testContext => promise<unit>) => unit = "skip"

  @module("vitest")
  external beforeAll: (unit => promise<unit>) => unit = "beforeAll"

  @module("vitest")
  external afterAll: (unit => promise<unit>) => unit = "afterAll"

  @module("vitest")
  external beforeEach: (unit => promise<unit>) => unit = "beforeEach"

  @module("vitest")
  external afterEach: (unit => promise<unit>) => unit = "afterEach"
}

// ============================================================================
// Expect
// ============================================================================

@module("vitest")
external expect: ('a, ~message: string=?) => expectation<'a> = "expect"
