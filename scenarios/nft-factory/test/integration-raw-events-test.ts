//LIBRARIES
import hre from "hardhat";
import { expect } from "chai";

//CODEGEN
import { nftFactoryAbi, simpleNftAbi } from "../generated/src/Abis.bs";
import { registerAllHandlers } from "../generated/src/RegisterHandlers.bs";
import { processAllEvents } from "../generated/src/EventSyncing.bs";
import { RawEvents } from "../generated/src/DbFunctions.bs";

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

  //Used again in last test
  let nftFactoryContractAddress: string;
  let simpleNftContractAddress: string;

  const { provider } = hre.ethers;
  const getlocalChainConfig = (
    nftFactoryContractAddress: string,
    simpleNftContractAddress: string
  ) => ({
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
  });

  before(async function() {
    this.timeout(30 * 1000);
    await runMigrationsNoLogs();
    console.log("deploying Nft Factory");
    const deployedNftFactory = await deployNftFactory();
    nftFactoryContractAddress = await deployedNftFactory.getAddress();
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
    simpleNftContractAddress = simplNftCreatedEvent.args.contractAddress;
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

    registerAllHandlers();
    console.log("processing events");
    const localChainConfig = getlocalChainConfig(
      nftFactoryContractAddress,
      simpleNftContractAddress
    );
    await processAllEvents(localChainConfig);
    console.log("Successfully processed events");
  });
  after(async () => {
    // await runMigrationsNoLogs();
  });

  it("RawEvents table contains rows after indexer runs", async function() {
    let rawEventsRows = await sql`SELECT * FROM public.raw_events`;
    expect(rawEventsRows.count).to.be.gt(0);
  });

  it("Entities have metrics and relate to their raw events", async function() {
    let joinedMetricsRows = await sql`
    SELECT t.db_write_timestamp AS t_write, t.event_chain_id, t.event_id, r.block_timestamp, r.db_write_timestamp AS r_write
    FROM public.token AS t
    JOIN public.raw_events AS r
    ON t.event_chain_id = r.chain_id AND t.event_id = r.event_id;
    `;
    expect(joinedMetricsRows.count).to.be.gt(0);
  });

  it("should ensure Entites are created correctly", async function() {
    let rowsNftcollection = await sql`SELECT * FROM public.nftcollection`;
    expect(rowsNftcollection.count).to.be.gt(0);
    let rowsUsers = await sql`SELECT * FROM public.user`;
    expect(rowsUsers.count).to.be.gt(0);
    let rowsToken = await sql`SELECT * FROM public.token`;
    expect(rowsToken.count).to.be.gt(0);
  });

  it("should return the highest blockNumber processed processeing event", async function() {
    type blockNumberRow = {
      block_number: number;
    };
    let chainId = 1337;
    let latestBlockRows: blockNumberRow[] =
      await RawEvents.readLatestRawEventsBlockNumberProcessedOnChainId(
        sql,
        chainId
      );

    let latestBlock = latestBlockRows[0].block_number;
    expect(latestBlock).to.be.eq(5);
  });

  it("latest block number function returns expected", async function() {
    let chainId = 1337;
    let latestBlockNumber = await RawEvents.getLatestProcessedBlockNumber(
      chainId
    );

    expect(latestBlockNumber).to.be.eq(5);
  });

  it("reprocesses only new blocks after new events", async function() {
    const mintTxs = [
      { user: Users.User1, quantity: 3 },
      { user: Users.User2, quantity: 6 },
    ].map((params) =>
      mintSimpleNft(params.user, simpleNftContractAddress, params.quantity)
    );

    await Promise.all(mintTxs);
    type blocksProcessed = {
      from: number;
      to: number;
    };
    const localChainConfig = getlocalChainConfig(
      nftFactoryContractAddress,
      simpleNftContractAddress
    );
    let processed: blocksProcessed = await processAllEvents(localChainConfig);

    expect(processed.from).to.be.gt(5);
  });
});
