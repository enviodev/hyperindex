//LIBRARIES
import { expect } from "chai";

//CODEGEN
import { registerAllHandlers } from "../generated/src/RegisterHandlers.bs";
import { runDownMigrations } from "../generated/src/db/Migrations.bs";

//HELPERS
import {
  Users,
  createNftFromFactory,
  mintSimpleNft,
} from "./helpers/node-and-contracts";
import { deployContracts } from "./helpers/setupNodeAndContracts";

import { runMigrationsNoLogs, createSql, EventVariants } from "./helpers/utils";

import {
  getLocalChainConfig,
  makeChainManager,
  startProcessing,
} from "./Integration_ts_helpers.gen";
// import { setLogLevel } from "generated/src/Logging.bs.js";
// require("mocha-reporter").hook(); //Outputs filename in error logs with mocha-reporter

describe("Raw Events Integration", () => {
  const sql = createSql();
  let simpleNftContractAddress: string;
  let nftFactoryContractAddress: string;
  let config: unknown;

  before(async function () {
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
    const _createNftTx = await createNftFromFactory(deployedNftFactory, {
      name: "test_name",
      symbol: "t_sym",
      supply: 200,
    });

    const simpleNftCreatedEventFilter =
      deployedNftFactory.getEvent("SimpleNftCreated");
    const eventQuery = await deployedNftFactory.queryFilter(
      simpleNftCreatedEventFilter
    );
    const simplNftCreatedEvent = eventQuery[0];

    const localChainConfig = getLocalChainConfig(nftFactoryContractAddress);
    config = registerAllHandlers();

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
    const chainManager = makeChainManager(localChainConfig);

    startProcessing(config, localChainConfig, chainManager);
    //Wait 0.5s for processing to occur it no longer finishes with a resolve
    await new Promise((res) =>
      setTimeout(() => {
        res(null);
      }, 1000)
    );
  });
  after(async () => {
    await runMigrationsNoLogs();
  });

  it("RawEvents table contains rows after indexer runs", async function () {
    let rawEventsRows = await sql`SELECT * FROM public.raw_events`;
    expect(rawEventsRows.count).to.be.gt(0);
  });

  it("should ensure Entites are created correctly", async function () {
    let rowsNftCollection = await sql`SELECT * FROM public."NftCollection"`;
    expect(rowsNftCollection.count).to.be.gt(0);
    let rowsUsers = await sql`SELECT * FROM public."User"`;
    expect(rowsUsers.count).to.be.gt(0);
    let rowsToken = await sql`SELECT * FROM public."Token"`;
    expect(rowsToken.count).to.be.gt(0);
  });

  it("should have 1 row in the dynamic_contract_registry table", async function () {
    let rowsDCR = await sql`SELECT * FROM public.dynamic_contract_registry`;
    console.log(rowsDCR);
    expect(rowsDCR.count).to.be.eq(1);
  });

  // TODO: Fix this test. This test broke after rebasing the 'dev-mode' code on the lastest main with the restructiring and dynamic contracts code.
  it.skip("Tracks dynamic contract on restart", async () => {
    let beforeRawEventsRows = await sql`SELECT * FROM public.raw_events`;
    //TODO: fix this test, This indicates this test is ineffective but the structure is what we want to test
    // below show that the contract address store is still populated with the contract
    console.log("new contract");

    mintSimpleNft(Users.User1, simpleNftContractAddress, 1);
    const localChainConfig = getLocalChainConfig(nftFactoryContractAddress);
    const chainManager = makeChainManager(localChainConfig);
    startProcessing(config, localChainConfig, chainManager);

    //Wait 2s for processing to occur
    await new Promise((res) =>
      setTimeout(() => {
        res(null);
      }, 500)
    );

    let afterRawEventsRows = await sql`SELECT * FROM public.raw_events`;
    expect(afterRawEventsRows.count).to.be.gt(beforeRawEventsRows.count);
  });

  it("RawEvents table does not exist after migration dropping raw events table", async function () {
    await runDownMigrations(false);
    let rawEventsRows = await sql`
        SELECT EXISTS (
          SELECT FROM information_schema.tables
          WHERE table_name = 'public.raw_events'
        );
      `;
    expect(rawEventsRows[0].exists).to.be.eq(false);
  });
});
