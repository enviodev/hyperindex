//LIBRARIES
import hre from "hardhat";
import { expect } from "chai";

//CODEGEN
import { nftFactoryAbi, simpleNftAbi } from "../generated/src/Abis.bs";
import { registerAllHandlers } from "../generated/src/RegisterHandlers.bs";

//HELPERS
import {
  Users,
  createNftFromFactory,
  mintSimpleNft,
} from "./helpers/node-and-contracts";
import { deployContracts } from "./helpers/setupNodeAndContracts.js";

import { runMigrationsNoLogs, createSql, EventVariants } from "./helpers/utils";
import { make, startFetchers } from "generated/src/ChainManager.bs";
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
      provider,
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
      syncConfig: {
        initialBlockInterval: 10000,
        backoffMultiplicative: 10000,
        accelerationAdditive: 10000,
        intervalCeiling: 10000,
        backoffMillis: 10000,
        queryTimeoutMillis: 10000,
      },
    };
  };

  before(async function() {
    this.timeout(30 * 1000);
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
    const chainManager = make(
      { [localChainConfig.chainId]: localChainConfig },
      ARB_QUEUE_SIZE
    );
    const logger = createChild("test child");
    startFetchers(chainManager);
    startProcessingEventsOnQueue(chainManager);
    //Wait 0.5s for processing to occur it no longer finishes with a resolve
    await new Promise((res) =>
      setTimeout(() => {
        res(null);
      }, 500)
    );
  });
  after(async () => {
    await runMigrationsNoLogs();
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
});
