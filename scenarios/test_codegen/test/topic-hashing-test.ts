import { TestHelpers } from "generated";
import { TestEvents } from "../contracts/typechain-types";
import Viem from "generated/src/bindings/Viem.bs.js";
import assert from "assert";
import { keccak256, encodeAbiParameters, encodePacked } from "viem";

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
  let checkedEvents = 0;

  after(() => {
    assert.equal(
      checkedEvents,
      allEvents.length,
      "All events should be checked"
    );
  });

  const checkEventFilter = async (eventName: any, topic1: any) => {
    if (!allEvents) {
      allEvents = await hre.ethers.provider.getLogs({
        address: await deployedTestEvents.getAddress(),
      });
    }
    const topic0 = deployedTestEvents.interface.getEvent(eventName).topicHash;
    const res = await hre.ethers.provider.getLogs({
      address: await deployedTestEvents.getAddress(),
      topics: [topic0, topic1],
    });
    console.log(eventName, res);

    assert.equal(res.length, 1);
    checkedEvents++;
  };

  it("Gets indexed uint topic with topic filter", async () => {
    await checkEventFilter(
      "IndexedUint",
      Viem.TopicFilter.fromBigInt(testParams.id)
    );
  });

  //TODO: get negative numbers working
  it.skip("get indexed int topic with topic filter", async () => {
    console.log(Viem.TopicFilter.toHexAndPad(-testParams.id));
    await checkEventFilter(
      "IndexedInt",
      // Viem.TopicFilter.fromBigInt(-testParams.id)
      undefined
    );
  });

  it("get indexed bool topic with topic filter", async () => {
    await checkEventFilter(
      "IndexedBool",
      Viem.TopicFilter.fromBool(testParams.isTrue)
    );
  });

  it("get indexed address topic with topic filter", async () => {
    await checkEventFilter(
      "IndexedAddress",
      Viem.TopicFilter.fromAddress(testParams.addr)
    );
  });

  it("get indexed bytes topic with topic filter", async () => {
    await checkEventFilter(
      "IndexedBytes",
      Viem.TopicFilter.fromDynamicBytes(testParams.dynBytes)
    );
  });

  it("get indexed fixedBytes32 topic with topic filter", async () => {
    await checkEventFilter(
      "IndexedFixedBytes",
      Viem.TopicFilter.fromBytes(testParams.fixedBytes32)
    );
  });

  it("get indexed string topic with topic filter", async () => {
    await checkEventFilter(
      "IndexedString",
      Viem.TopicFilter.fromString(testParams.str)
    );
  });

  it("get indexed struct topic with topic filter", async () => {
    // Step 1: Define the struct parameters according to their types
    const structParameters = [
      { type: "uint256", value: testParams.id },
      { type: "string", value: testParams.str },
    ];

    // Step 2: Encode the parameters using ABI encoding
    const encodedData = encodeAbiParameters(
      [
        { type: "uint256", name: "id" },
        { type: "string", name: "name" },
      ],
      [50n, testParams.str]
    );
    const encodedData2 = encodePacked(
      ["uint256", "string"],
      [testParams.id, testParams.str]
    );
    console.log("encodedData", encodedData);
    console.log("encodedData2", encodedData2);
    const topic1 = keccak256(encodedData);
    console.log("topic1", topic1);
    console.log("topic1 2", keccak256(encodedData2));
    const test = keccak256(
      (Viem.TopicFilter.fromBigInt(testParams.id) +
        Viem.TopicFilter.toHex(testParams.str).slice(2)) as any
    );
    console.log("test", test);

    await checkEventFilter("IndexedStruct", undefined);
  });
});
