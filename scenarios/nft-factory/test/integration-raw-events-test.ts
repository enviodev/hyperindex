//LIBRARIES
import hre from "hardhat";
import { expect } from "chai";

//CODEGEN
import { nftFactoryAbi, simpleNftAbi } from "../generated/src/Abis.bs";
import { registerAllHandlers } from "../generated/src/RegisterHandlers.bs";
import { processAllEvents } from "../generated/src/EventSyncing.bs";

//HELPERS
import {
  Users,
  createNftFromFactory,
  deployNftFactory,
  mintSimpleNft,
} from "./helpers/node-and-contracts";
import { runMigrationsNoLogs, sql, EventVariants } from "./helpers/utils";

require("mocha-reporter").hook(); //Outputs filename in error logs with mocha-reporter

describe("Raw Events Integration", () => {
  before(async () => {
    await runMigrationsNoLogs();
  });
  after(async () => {
    await runMigrationsNoLogs();
  });

  it("RawEvents table contains rows after indexer runs", async () => {
    console.log("deploying Nft Factory");
    const deployedNftFactory = await deployNftFactory();
    const nftFactoryContractAddress = await deployedNftFactory.getAddress();
    console.log(
      "Successfully deployed nftFactory at",
      nftFactoryContractAddress
    );

    console.log("Creating Nft");
    const createNftTx = await createNftFromFactory(deployedNftFactory, {
      name: "test_name",
      symbol: "t_sym",
      supply: 200,
    });

    const simpleNftCreatedEventFilter =
      deployedNftFactory.getEvent("SimpleNftCreated");
    const eventQuery = await deployedNftFactory.queryFilter(
      simpleNftCreatedEventFilter,
      createNftTx.hash
    );
    const simplNftCreatedEvent = eventQuery[0];
    const simpleNftContractAddress = simplNftCreatedEvent.args.contractAddress;
    console.log("Created NFT at: ", simpleNftContractAddress);

    console.log("Minting Nft from user 1, 2 and 3");

    const mintTxs = [
      { user: Users.User1, quantity: 1 },
      { user: Users.User2, quantity: 3 },
      { user: Users.User3, quantity: 5 },
    ].map((params) =>
      mintSimpleNft(params.user, simpleNftContractAddress, params.quantity)
    );

    await Promise.all(mintTxs);

    console.log("Successfully minted");

    const { provider } = hre.ethers;
    const localChainConfig = {
      provider,
      startBlock: 0,
      chainId: 31337,
      contracts: [
        {
          name: "NftFactory",
          abi: nftFactoryAbi,
          address: nftFactoryContractAddress,
          events: [EventVariants.NftFactoryContract_SimpleNftCreatedEvent],
        },
        {
          name: "SimpleNft",
          abi: simpleNftAbi,
          address: simpleNftContractAddress,
          events: [EventVariants.SimpleNftContract_TransferEvent],
        },
      ],
    };

    registerAllHandlers();
    console.log("processing events");
    await processAllEvents(localChainConfig);
    console.log("Successfully processed events");

    let rawEventsRows = await sql`SELECT * FROM public.raw_events`;

    expect(rawEventsRows.count).to.be.gt(0);

    console.log(rawEventsRows);
  });
});
