import {
  Users,
  createNftFromFactory,
  deployNftFactory,
  mintSimpleNft,
} from "./helpers/node-and-contracts";

describe("integration", () => {
  it("says hi", async () => {
    console.log("deploying Nft Factory");
    const deployedNftFactory = await deployNftFactory();
    console.log("Successfully deployed");

    console.log("Creating Nft");
    let createNftTx = await createNftFromFactory(deployedNftFactory, {
      name: "test_name",
      symbol: "t_sym",
      supply: 200,
    });

    let simpleNftCreatedEventFilter =
      deployedNftFactory.getEvent("SimpleNftCreated");
    let eventQuery = await deployedNftFactory.queryFilter(
      simpleNftCreatedEventFilter,
      createNftTx.hash
    );
    let simplNftCreatedEvent = eventQuery[0];
    let simpleNftContractAddress = simplNftCreatedEvent.args.contractAddress;
    console.log("Created NFT at: ", simpleNftContractAddress);

    console.log("Minting Nft from user 1, 2 and 3");

    let mintTxs = [
      { user: Users.User1, quantity: 1 },
      { user: Users.User2, quantity: 3 },
      { user: Users.User2, quantity: 5 },
    ].map((params) =>
      mintSimpleNft(params.user, simpleNftContractAddress, params.quantity)
    );

    await Promise.all(mintTxs);

    console.log("Successfully minted");
  });
});
