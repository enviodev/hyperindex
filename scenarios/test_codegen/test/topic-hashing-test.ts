import { TestEvents as GeneratedTestEvents } from "../generated/src/Types.res.js";

// @ts-ignore
import { GetLogs } from "envio/src/sources/Rpc.res.js";
import { TestEvents } from "../contracts/typechain-types";
import assert from "assert";
import { hashingTestParams } from "../src/EventHandlers";

const hre = require("hardhat");

let deployedTestEvents: TestEvents;

describe("Topic Hashing", () => {
  before(async function () {
    this.timeout(30 * 1000);
    await hre.run("compile");

    let accounts = await hre.ethers.getSigners();
    let deployer = accounts[0];

    const TestEvents = (
      await hre.ethers.getContractFactory("TestEvents")
    ).connect(deployer);

    deployedTestEvents = await TestEvents.deploy();
    await deployedTestEvents.emitTestEvents(
      hashingTestParams.id,
      hashingTestParams.addr,
      hashingTestParams.str,
      hashingTestParams.isTrue,
      hashingTestParams.dynBytes,
      hashingTestParams.fixedBytes32
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

  const checkEventFilter = async (eventMod: {
    sighash: string;
    register: () => {
      name: string;
      getEventFiltersOrThrow: (chain: number) => {
        _0: unknown;
      };
    };
  }) => {
    let eventConfig = eventMod.register();
    const topics = GetLogs.mapTopicQuery(
      (eventConfig.getEventFiltersOrThrow(1)._0 as unknown[])[0]
    );

    const res = await hre.ethers.provider.getLogs({
      address: await deployedTestEvents.getAddress(),
      topics,
    });

    assert.equal(res.length, 1, "Should return a single event");
    checkedEvents[eventConfig.name] = eventMod.sighash;
  };

  it("Gets indexed uint topic with topic filter", async () => {
    await checkEventFilter(GeneratedTestEvents.IndexedUint);
  });

  it("get indexed int topic with topic filter", async () => {
    await checkEventFilter(GeneratedTestEvents.IndexedInt);
  });

  it("get indexed bool topic with topic filter", async () => {
    await checkEventFilter(GeneratedTestEvents.IndexedBool);
  });

  it("get indexed address topic with topic filter", async () => {
    await checkEventFilter(GeneratedTestEvents.IndexedAddress);
  });

  it("get indexed bytes topic with topic filter", async () => {
    await checkEventFilter(GeneratedTestEvents.IndexedBytes);
  });

  it("get indexed fixedBytes32 topic with topic filter", async () => {
    await checkEventFilter(GeneratedTestEvents.IndexedFixedBytes);
  });

  it("get indexed string topic with topic filter", async () => {
    await checkEventFilter(GeneratedTestEvents.IndexedString);
  });

  it("get indexed struct topic with topic filter", async () => {
    await checkEventFilter(GeneratedTestEvents.IndexedStruct);
  });

  it("get indexed array topic with topic filter", async () => {
    await checkEventFilter(GeneratedTestEvents.IndexedArray);
  });

  it("get indexed fixed array topic with topic filter", async () => {
    await checkEventFilter(GeneratedTestEvents.IndexedFixedArray);
  });

  it("get indexed nested array topic with topic filter", async () => {
    await checkEventFilter(GeneratedTestEvents.IndexedNestedArray);
  });

  it("get indexed struct array topic with topic filter", async () => {
    await checkEventFilter(GeneratedTestEvents.IndexedStructArray);
  });

  it("get indexed nested struct topic with topic filter", async () => {
    await checkEventFilter(GeneratedTestEvents.IndexedNestedStruct);
  });

  it("get indexed struct with array topic with topic filter", async () => {
    await checkEventFilter(GeneratedTestEvents.IndexedStructWithArray);
  });
});
