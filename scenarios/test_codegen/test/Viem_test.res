open RescriptMocha

@module("viem") external parseAbi: array<string> => Ethers.abi = "parseAbi"

describe("decodeEventLogOrThrow", () => {
  it("decodes event with args as an object", () => {
    let eventLog: Viem.eventLog = {
      {
        abi: parseAbi([
          "event PoolCreated(address indexed token0, address indexed token1, uint24 indexed fee, int24 tickSpacing, address pool)",
        ]),
        data: "0x000000000000000000000000000000000000000000000000000000000000003c000000000000000000000000e13514aacc27a3dfd2ae0db6ada4ef7658c1e435",
        topics: [
          "0x783cca1c0412dd0d695e784568c96da2e9c22ff989357a2e8b1d9b2b4e6b7118",
          "0x00000000000000000000000027d2decb4bfc9c76f0309b8e88dec3a601fe25a8",
          "0x0000000000000000000000004200000000000000000000000000000000000006",
          "0x0000000000000000000000000000000000000000000000000000000000000bb8",
        ],
      }
    }
    let decodedEvent = eventLog->Viem.decodeEventLogOrThrow

    Assert.deepEqual(
      decodedEvent,
      {
        args: {
          "fee": 3000,
          "pool": "0xe13514AaCc27a3dFd2ae0db6aDA4eF7658c1E435",
          "tickSpacing": 60,
          "token0": "0x27D2DECb4bFC9C76F0309b8E88dec3a601Fe25a8",
          "token1": "0x4200000000000000000000000000000000000006",
        },
        eventName: "PoolCreated",
      },
    )
  })

  it("if there's a param without name, it decodes as an array, which we don't want", () => {
    let eventLog: Viem.eventLog = {
      {
        abi: parseAbi([
          "event PairCreated(address indexed token0, address indexed token1, address pair, uint256)",
        ]),
        data: "0x0000000000000000000000001cc744d0891457e16e94426ea4357662a9a9ba5000000000000000000000000000000000000000000000000000000000000001c1",
        topics: [
          "0x0d3648bd0f6ba80134a33ba9275ac585d9d315f0ad8355cddefde31afa28d0e9",
          "0x0000000000000000000000004200000000000000000000000000000000000006",
          "0x0000000000000000000000006d521550fc0e937cd3f4db0b17bbc256f5bfd140",
        ],
      }
    }
    let decodedEvent = eventLog->Viem.decodeEventLogOrThrow

    Assert.deepEqual(
      decodedEvent,
      {
        args: [
          "0x4200000000000000000000000000000000000006",
          "0x6D521550fc0E937CD3f4dB0B17Bbc256F5bFd140",
          "0x1CC744d0891457E16e94426EA4357662A9A9bA50",
          "449",
        ],
        eventName: "PairCreated",
      },
    )
    // We don't want that /|\ to be an array, so we need to output abi with the param names
  })
})
