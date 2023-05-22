import type { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { task } from "hardhat/config";
import type { TaskArguments } from "hardhat/types";

import type { Greeter } from "../../types/Greeter";
import type { Greeter__factory } from "../../types/factories/Greeter__factory";

task("deploy:Greeter")
  .addParam("greeting", "Say hello, be nice")
  .setAction(async function (taskArguments: TaskArguments, { ethers }) {
    const signers: SignerWithAddress[] = await ethers.getSigners();
    const greeterFactory: Greeter__factory = <Greeter__factory>await ethers.getContractFactory("Greeter");
    const greeter: Greeter = <Greeter>await greeterFactory.connect(signers[0]).deploy(taskArguments.greeting);
    await greeter.deployed();
    await greeter.setGreeting("yeah boooi");
    await greeter.setGreeting("yeah boooi again");
    console.log("Greeter deployed to: ", greeter.address);
  });

// task("task1")
//   .addParam("greeting", "Hola, como estas?")
//   .setAction(async function (taskArguments: TaskArguments, { ethers}, deployments) {
//     const signers: SignerWithAddress[] = await ethers.getSigners();
//     const greeterFactory: Greeter__factory = <Greeter__factory>await ethers.getContractFactory("Greeter");
//     const greeter: Greeter = <Greeter>await greeterFactory.connect(signers[0]).deploy(taskArguments.greeting);
//     await greeter.deployed();
//     console.log("Greeter deployed to: ", greeter.address);

//     // const Greeter = await deployments.get("Greeter");
// //     console.log("SimpleBank deployment retrieved.");

// //     const simpleBank = await ethers.getContractAt(
// //       "SimpleBank",
// //       SimpleBank.address
// //     );

// //     const newDeposit1Tx = await simpleBank
// //       .connect(user)
// //       .deposit(Number(amount));
// //     console.log("New deposit made.");
// //     await newDeposit1Tx.wait();

//   });

//   const accounts = await ethers.getSigners();
//     const provider = ethers.provider;
//     const user = accounts[userIndex % accounts.length];
//

//     const SimpleBank = await deployments.get("SimpleBank");
//     console.log("SimpleBank deployment retrieved.");

//     const simpleBank = await ethers.getContractAt(
//       "SimpleBank",
//       SimpleBank.address
//     );

//     const newDeposit1Tx = await simpleBank
//       .connect(user)
//       .deposit(Number(amount));
//     console.log("New deposit made.");
//     await newDeposit1Tx.wait();

//     let accountCheck = await simpleBank.getBalance(user.address);
//     console.log("deposit made", accountCheck);

//     await increaseTime(provider, 1800);
//   });

// async function increaseTime(provider, seconds) {
//   await provider.send("evm_increaseTime", [seconds]);
//   await provider.send("evm_mine");
