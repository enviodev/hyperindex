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
import { runMigrationsNoLogs, createSql, EventVariants } from "./helpers/utils";

require("mocha-reporter").hook(); //Outputs filename in error logs with mocha-reporter

describe("Raw Events Integration", () => {
  const sql = createSql();

  before(async function () {
    this.timeout(30 * 1000);
    await runMigrationsNoLogs();
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
    console.log("Successfully created Nft", createNftTx);

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
      chainId: 1337,
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
  });
  after(async () => {
    await runMigrationsNoLogs();
  });

  it("RawEvents table contains rows after indexer runs", async function () {
    let rawEventsRows = await sql`SELECT * FROM public.raw_events`;
    expect(rawEventsRows.count).to.be.gt(0);
  });

  it("Entities have metrics and relate to their raw events", async function () {
    let joinedMetricsRows = await sql`
    SELECT t.db_write_timestamp AS t_write, t.event_chain_id, t.event_id, r.block_timestamp, r.db_write_timestamp AS r_write
    FROM public.token AS t
    JOIN public.raw_events AS r
    ON t.event_chain_id = r.chain_id AND t.event_id = r.event_id;
    `;
    expect(joinedMetricsRows.count).to.be.gt(0);
  });

  it("should ensure Entites are created correctly", async function () {
    let rowsNftcollection = await sql`SELECT * FROM public.nftcollection`;
    expect(rowsNftcollection.count).to.be.gt(0);
    let rowsUsers = await sql`SELECT * FROM public.user`;
    expect(rowsUsers.count).to.be.gt(0);
    let rowsToken = await sql`SELECT * FROM public.token`;
    expect(rowsToken.count).to.be.gt(0);
  });
});
