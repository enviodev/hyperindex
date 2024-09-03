import { TestEvents as GeneratedTestEvents } from "../generated/src/Types.bs.js";
import {
  TestEvents_IndexedAddress_eventFilter,
  TestEvents_IndexedBool_eventFilter,
  TestEvents_IndexedBytes_eventFilter,
  TestEvents_IndexedFixedBytes_eventFilter,
  TestEvents_IndexedString_eventFilter,
  TestEvents_IndexedStruct_eventFilter,
  TestEvents_IndexedUint_eventFilter,
} from "generated";
import { mapTopicQuery } from "generated/src/eventFetching/rpc/Rpc.bs.js";
import { TestHelpers } from "generated";
import { TestEvents } from "../contracts/typechain-types";
import TopicFilter from "generated/src/TopicFilter.bs.js";
import assert from "assert";
import {
  keccak256,
  encodeAbiParameters,
  encodePacked,
  stringToHex,
  numberToHex,
  concat,
} from "viem";

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

describe.only("Topic Hashing", () => {
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
    const _res = await deployedTestEvents.emitTestEvents(
      testParams.id,
      testParams.addr,
      testParams.str,
      testParams.isTrue,
      testParams.dynBytes,
      testParams.fixedBytes32
    );
  });

  let allEvents: any[];
  let checkedEvents: Record<string, string> = {};

  after(() => {
    for (const [key, val] of Object.entries(GeneratedTestEvents)) {
      if (!!val.sighash && !checkedEvents[key]) {
        assert.fail(`Event ${key} was not checked`);
      }
    }
  });

  const checkEventFilter = async (eventMod: any, filter: any) => {
    if (!allEvents) {
      allEvents = await hre.ethers.provider.getLogs({
        address: await deployedTestEvents.getAddress(),
      });
    }
    const topics = mapTopicQuery(eventMod.getTopicSelection(filter));
    console.log("topics", topics);
    const res = await hre.ethers.provider.getLogs({
      address: await deployedTestEvents.getAddress(),
      topics,
    });
    console.log(eventMod.name, res);

    assert.equal(res.length, 1);
    checkedEvents[eventMod.name] = eventMod.sighash;
  };

  it("Gets indexed uint topic with topic filter", async () => {
    const filter: TestEvents_IndexedUint_eventFilter = { num: [testParams.id] };
    await checkEventFilter(GeneratedTestEvents.IndexedUint, filter);
  });

  it("get indexed int topic with topic filter", async () => {
    const filter: TestEvents_IndexedUint_eventFilter = {
      //TODO: get negative numbers working
      // num: [-testParams.id],
      num: [],
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

  it("get indexed struct topic with topic filter", async () => {
    const filter: TestEvents_IndexedStruct_eventFilter = {
      testStruct: [[testParams.id, testParams.str]],
    };
    await checkEventFilter(GeneratedTestEvents.IndexedStruct, filter);
  });

  it.only("same values", () => {
    const str = "hi";
    const withHex = keccak256(stringToHex(str, { size: 32 }));
    const wihoutHex = keccak256(str as any);

    console.log(withHex, wihoutHex);
    assert.equal(withHex, wihoutHex);
  });
});
