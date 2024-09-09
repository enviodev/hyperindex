import { TestEvents as GeneratedTestEvents } from "../generated/src/Types.bs.js";
import {
  TestEvents_IndexedAddress_eventFilter,
  TestEvents_IndexedBool_eventFilter,
  TestEvents_IndexedBytes_eventFilter,
  TestEvents_IndexedFixedBytes_eventFilter,
  TestEvents_IndexedString_eventFilter,
  TestEvents_IndexedStruct_eventFilter,
  TestEvents_IndexedUint_eventFilter,
  TestEvents_IndexedArray_eventFilter,
  TestEvents_IndexedFixedArray_eventFilter,
  TestEvents_IndexedNestedArray_eventFilter,
  TestEvents_IndexedStructArray_eventFilter,
  TestEvents_IndexedNestedStruct_eventFilter,
  TestEvents_IndexedStructWithArray_eventFilter,
} from "generated/src/Types.gen";
import { mapTopicQuery } from "generated/src/eventFetching/rpc/Rpc.bs.js";
import { TestHelpers } from "generated";
import { TestEvents } from "../contracts/typechain-types";
import assert from "assert";

const hre = require("hardhat");

let deployedTestEvents: TestEvents;

const testParams = {
  id: 50n,
  addr: TestHelpers.Addresses.mockAddresses[0],
  str: "test",
  isTrue: true,
  dynBytes: new Uint8Array([1, 2, 3, 4, 5, 6, 7, 9]),
  fixedBytes32: new Uint8Array(32).fill(0x12),
  // "0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef",
};

describe("Topic Hashing", () => {
  before(async function () {
    this.timeout(30 * 1000);
    await hre.run("compile");

    let accounts = await hre.ethers.getSigners();
    let deployer = accounts[0];
    testParams.addr = accounts[1].address;

    const TestEvents = (
      await hre.ethers.getContractFactory("TestEvents")
    ).connect(deployer);

    deployedTestEvents = await TestEvents.deploy();
    await deployedTestEvents.emitTestEvents(
      testParams.id,
      testParams.addr,
      testParams.str,
      testParams.isTrue,
      testParams.dynBytes,
      testParams.fixedBytes32
    );
  });

  let checkedEvents: Record<string, string> = {};

  after(() => {
    //Check that all events have been tested
    for (const [key, val] of Object.entries(GeneratedTestEvents)) {
      if (!!val.sighash && !checkedEvents[key]) {
        assert.fail(`Event ${key} was not checked`);
      }
    }
  });

  const checkEventFilter = async (eventMod: any, filter: any) => {
    const topics = mapTopicQuery(eventMod.getTopicSelection(filter)[0]);
    const res = await hre.ethers.provider.getLogs({
      address: await deployedTestEvents.getAddress(),
      topics,
    });

    assert.equal(res.length, 1);
    checkedEvents[eventMod.name] = eventMod.sighash;
  };

  it("Gets indexed uint topic with topic filter", async () => {
    const filter: TestEvents_IndexedUint_eventFilter = { num: [testParams.id] };
    await checkEventFilter(GeneratedTestEvents.IndexedUint, filter);
  });

  it("get indexed int topic with topic filter", async () => {
    const filter: TestEvents_IndexedUint_eventFilter = {
      num: [-testParams.id],
    };
    await checkEventFilter(GeneratedTestEvents.IndexedInt, filter);
  });

  it("get indexed bool topic with topic filter", async () => {
    const filter: TestEvents_IndexedBool_eventFilter = {
      isTrue: [testParams.isTrue],
    };
    await checkEventFilter(GeneratedTestEvents.IndexedBool, filter);
  });

  it("get indexed address topic with topic filter", async () => {
    const filter: TestEvents_IndexedAddress_eventFilter = {
      addr: [testParams.addr],
    };
    await checkEventFilter(GeneratedTestEvents.IndexedAddress, filter);
  });

  it("get indexed bytes topic with topic filter", async () => {
    const filter: TestEvents_IndexedBytes_eventFilter = {
      dynBytes: [testParams.dynBytes as any],
    };
    await checkEventFilter(GeneratedTestEvents.IndexedBytes, filter);
  });

  it("get indexed fixedBytes32 topic with topic filter", async () => {
    const filter: TestEvents_IndexedFixedBytes_eventFilter = {
      fixedBytes: [testParams.fixedBytes32 as any],
    };
    await checkEventFilter(GeneratedTestEvents.IndexedFixedBytes, filter);
  });

  it("get indexed string topic with topic filter", async () => {
    const filter: TestEvents_IndexedString_eventFilter = {
      str: [testParams.str],
    };
    await checkEventFilter(GeneratedTestEvents.IndexedString, filter);
  });

  type testStruct = [bigint, string];
  const testStruct: testStruct = [testParams.id, testParams.str];
  it("get indexed struct topic with topic filter", async () => {
    const filter: TestEvents_IndexedStruct_eventFilter = {
      testStruct: [testStruct],
    };
    await checkEventFilter(GeneratedTestEvents.IndexedStruct, filter);
  });

  it("get indexed array topic with topic filter", async () => {
    const filter: TestEvents_IndexedArray_eventFilter = {
      array: [[testParams.id, testParams.id + 1n]],
    };
    await checkEventFilter(GeneratedTestEvents.IndexedArray, filter);
  });

  it("get indexed fixed array topic with topic filter", async () => {
    const filter: TestEvents_IndexedFixedArray_eventFilter = {
      array: [[testParams.id, testParams.id + 1n]],
    };
    await checkEventFilter(GeneratedTestEvents.IndexedFixedArray, filter);
  });

  it("get indexed nested array topic with topic filter", async () => {
    const filter: TestEvents_IndexedNestedArray_eventFilter = {
      array: [
        [
          [testParams.id, testParams.id],
          [testParams.id, testParams.id],
        ],
      ],
    };
    await checkEventFilter(GeneratedTestEvents.IndexedNestedArray, filter);
  });

  it("get indexed struct array topic with topic filter", async () => {
    const filter: TestEvents_IndexedStructArray_eventFilter = {
      array: [[testStruct, testStruct]],
    };
    await checkEventFilter(GeneratedTestEvents.IndexedStructArray, filter);
  });

  it("get indexed nested struct topic with topic filter", async () => {
    type nestedStruct = [bigint, testStruct];
    const nestedStruct: nestedStruct = [testParams.id, testStruct];
    const filter: TestEvents_IndexedNestedStruct_eventFilter = {
      nestedStruct: [nestedStruct],
    };
    await checkEventFilter(GeneratedTestEvents.IndexedNestedStruct, filter);
  });

  it("get indexed struct with array topic with topic filter", async () => {
    type structWithArray = [bigint[], string[]];
    const structWithArray: structWithArray = [
      [testParams.id, testParams.id + 1n],
      [testParams.str, testParams.str],
    ];
    const filter: TestEvents_IndexedStructWithArray_eventFilter = {
      structWithArray: structWithArray,
    };
    await checkEventFilter(GeneratedTestEvents.IndexedStructWithArray, filter);
  });
});
