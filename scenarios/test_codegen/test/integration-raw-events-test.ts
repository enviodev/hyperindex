//LIBRARIES
import hre from "hardhat";
import { expect } from "chai";

//CODEGEN
import { nftFactoryAbi, simpleNftAbi } from "../generated/src/Abis.bs";
import { registerAllHandlers } from "../generated/src/RegisterHandlers.bs";
import { setLogLevel } from "../generated/src/Logging.bs";
import {
  runDownMigrations,
  runUpMigrations,
} from "../generated/src/Migrations.bs";

//HELPERS
import {
  Users,
  createNftFromFactory,
  mintSimpleNft,
} from "./helpers/node-and-contracts";
import { deployContracts } from "./helpers/setupNodeAndContracts.js";

import { runMigrationsNoLogs, createSql, EventVariants } from "./helpers/utils";
import {
  make,
  startFetchers,
} from "generated/src/eventFetching/ChainManager.bs";
import { startProcessingEventsOnQueue } from "generated/src/EventProcessing.bs";
import { createChild } from "generated/src/Logging.bs";

// require("mocha-reporter").hook(); //Outputs filename in error logs with mocha-reporter

describe("Raw Events Integration", () => {
  const sql = createSql();
  let simpleNftContractAddress: string;
  let nftFactoryContractAddress: string;
  const getlocalChainConfig = (nftFactoryContractAddress: string) => {
    const { provider } = hre.ethers;

    return {
      syncSource: {
        TAG: /* Rpc */ 0,
        _0: {
          provider,
          syncConfig: {
            initialBlockInterval: 10000,
            backoffMultiplicative: 10000,
            accelerationAdditive: 10000,
            intervalCeiling: 10000,
            backoffMillis: 10000,
            queryTimeoutMillis: 10000,
          },
        },
      },
      startBlock: 1,
      chainId: 1337,
      contracts: [
        {
          name: "NftFactory",
          abi: nftFactoryAbi,
          addresses: [nftFactoryContractAddress],
          events: [EventVariants.NftFactoryContract_SimpleNftCreatedEvent],
        },
        {
          name: "SimpleNft",
          abi: simpleNftAbi,
          addresses: [],
          events: [EventVariants.SimpleNftContract_TransferEvent],
        },
      ],
    };
  };

  before(async function() {
    this.timeout(30 * 1000);
    // setLogLevel("trace");

    await runMigrationsNoLogs();
    console.log("deploying Nft Factory");
    const deployedNftFactory = (await deployContracts()).nftFactory;
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

    const simpleNftCreatedEventFilter =
      deployedNftFactory.getEvent("SimpleNftCreated");
    const eventQuery = await deployedNftFactory.queryFilter(
      simpleNftCreatedEventFilter,
      createNftTx.hash
    );
    const simplNftCreatedEvent = eventQuery[0];

    const localChainConfig = getlocalChainConfig(nftFactoryContractAddress);
    registerAllHandlers();

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
    console.log("Successfully processed events");

    console.log("processing events after mint");
    const ARB_QUEUE_SIZE = 100;
    const SHOULD_SYNC_FROM_RAW_EVENTS = false;
    const chainManager = make(
      { [localChainConfig.chainId]: localChainConfig },
      ARB_QUEUE_SIZE,
      SHOULD_SYNC_FROM_RAW_EVENTS
    );
    const logger = createChild("test child");
    startFetchers(chainManager);
    startProcessingEventsOnQueue(chainManager);
    //Wait 0.5s for processing to occur it no longer finishes with a resolve
    await new Promise((res) =>
      setTimeout(() => {
        res(null);
      }, 2000)
    );
  });
  after(async () => {
    await runMigrationsNoLogs();
  });

  it("RawEvents table contains rows after indexer runs", async function() {
    let rawEventsRows = await sql`SELECT * FROM public.raw_events`;
    expect(rawEventsRows.count).to.be.gt(0);
  });

  it("should ensure Entites are created correctly", async function() {
    let rowsNftCollection = await sql`SELECT * FROM public."NftCollection"`;
    expect(rowsNftCollection.count).to.be.gt(0);
    let rowsUsers = await sql`SELECT * FROM public."User"`;
    expect(rowsUsers.count).to.be.gt(0);
    let rowsToken = await sql`SELECT * FROM public."Token"`;
    expect(rowsToken.count).to.be.gt(0);
  });

  it("should have 1 row in the dynamic_contract_registry table", async function() {
    let rowsDCR = await sql`SELECT * FROM public.dynamic_contract_registry`;
    console.log(rowsDCR);
    expect(rowsDCR.count).to.be.eq(1);
  });

  it("Tracks dynamic contract on restart", async () => {
    let beforeRawEventsRows = await sql`SELECT * FROM public.raw_events`;
    //TODO: fix this test, This indicates this test is ineffective but the structure is what we want to test
    // below show that the contract address store is still populated with the contract
    console.log("new contract");

    mintSimpleNft(Users.User1, simpleNftContractAddress, 1);
    const localChainConfig = getlocalChainConfig(nftFactoryContractAddress);
    const ARB_QUEUE_SIZE = 100;
    const chainManager = make(
      { [localChainConfig.chainId]: localChainConfig },
      ARB_QUEUE_SIZE
    );
    startFetchers(chainManager);
    startProcessingEventsOnQueue(chainManager);

    //Wait 2s for processing to occur
    await new Promise((res) =>
      setTimeout(() => {
        res(null);
      }, 500)
    );

    let afterRawEventsRows = await sql`SELECT * FROM public.raw_events`;
    expect(afterRawEventsRows.count).to.be.gt(beforeRawEventsRows.count);
  });

  it("RawEvents table does contains rows after migration keeping raw events table", async function() {
    await runDownMigrations(false, false);
    let rawEventsRows = await sql`SELECT * FROM public.raw_events`;
    expect(rawEventsRows.count).to.be.gt(0);
  });

  it("RawEvents table does not exist after migration dropping raw events table", async function() {
    await runDownMigrations(false, true);
    let rawEventsRows = await sql`
        SELECT EXISTS (
          SELECT FROM information_schema.tables
          WHERE table_name = 'public.raw_events'
        );
      `;
    expect(rawEventsRows[0].exists).to.be.eq(false);
  });
});
