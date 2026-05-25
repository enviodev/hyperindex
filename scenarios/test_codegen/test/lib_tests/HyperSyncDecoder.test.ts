import { describe, it, expect } from "vitest";
import { encodeAbiParameters, encodeEventTopics, toEventSelector } from "viem";
// @ts-ignore – internal module
import { Decoder } from "envio/src/sources/HyperSyncClient.res.mjs";
// @ts-ignore – internal module
import * as EventConfigBuilder from "envio/src/EventConfigBuilder.res.mjs";

const sigAllIndexed =
  "Transfer(address indexed from, address indexed to, uint256 indexed value)";
const sigNoneIndexed = "Transfer(address from, address to, uint256 value)";

const sighash = toEventSelector("event Transfer(address, address, uint256)");

const from = "0x000000000000000000000000000000000000aaaa";
const to = "0x000000000000000000000000000000000000bbbb";
const value = 42n;

function makeLog(topics: `0x${string}`[], data: `0x${string}`) {
  return { log: { topics, data } };
}

const allIndexedLog = makeLog(
  encodeEventTopics({
    abi: [
      {
        type: "event",
        name: "Transfer",
        inputs: [
          { type: "address", name: "from", indexed: true },
          { type: "address", name: "to", indexed: true },
          { type: "uint256", name: "value", indexed: true },
        ],
      },
    ] as const,
    eventName: "Transfer",
    args: { from, to, value },
  }) as `0x${string}`[],
  "0x"
);

const noneIndexedLog = makeLog(
  [sighash],
  encodeAbiParameters(
    [
      { type: "address", name: "from" },
      { type: "address", name: "to" },
      { type: "uint256", name: "value" },
    ],
    [from, to, value]
  )
);

describe("HyperSync decoder – same sighash, different indexed layouts", () => {
  it("native decoder correctly splits indexed vs body for both layouts", async () => {
    const decoder = Decoder.fromSignatures([sigAllIndexed, sigNoneIndexed]);

    const [decodedAll, decodedNone] = await decoder.decodeEvents([
      allIndexedLog,
      noneIndexedLog,
    ]);

    expect(decodedAll.indexed).toHaveLength(3);
    expect(decodedAll.body).toHaveLength(0);
    expect(decodedNone.indexed).toHaveLength(0);
    expect(decodedNone.body).toHaveLength(3);
  });

  it("end-to-end: convertHyperSyncEventArgs produces correct named params for both layouts", async () => {
    const decoder = Decoder.fromSignatures([sigAllIndexed, sigNoneIndexed]);

    const [decodedAll, decodedNone] = await decoder.decodeEvents([
      allIndexedLog,
      noneIndexedLog,
    ]);

    const allIndexedParams = [
      { name: "from", abiType: "address", indexed: true },
      { name: "to", abiType: "address", indexed: true },
      { name: "value", abiType: "uint256", indexed: true },
    ];
    const noneIndexedParams = [
      { name: "from", abiType: "address", indexed: false },
      { name: "to", abiType: "address", indexed: false },
      { name: "value", abiType: "uint256", indexed: false },
    ];

    const convertAll =
      EventConfigBuilder.buildHyperSyncDecoder(allIndexedParams);
    const convertNone =
      EventConfigBuilder.buildHyperSyncDecoder(noneIndexedParams);

    const paramsAll = convertAll(decodedAll);
    const paramsNone = convertNone(decodedNone);

    expect(paramsAll).toEqual({ from, to, value });
    expect(paramsNone).toEqual({ from, to, value });
  });
});
