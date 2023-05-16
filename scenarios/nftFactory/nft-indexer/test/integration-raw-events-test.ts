import { deployContract } from "./helpers/node-and-contracts";

describe("integration", () => {
  it("says hi", async () => {
    const contract = await deployContract();
    console.log("hi", contract);
    console.log("hi");
  });
});
