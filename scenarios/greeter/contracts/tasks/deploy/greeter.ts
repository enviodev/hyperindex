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
    if ("0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3" != greeter.address) {
      throw new Error("Silly deployment script shouldnt be a task, find me in the code to edit");
    }
    console.log("Greeter deployed to: ", greeter.address);
  });

// > warning: because the template uses a task to deploy the contracts the deployed greeter contract is not accessible in the hre.deployments
task("task:setGreeting")
  .addParam("greeting", "Say hello, be nice")
  .setAction(async function (taskArguments: TaskArguments, hre) {
    let { ethers, deployments } = hre;

    console.log(deployments);

    const signers: SignerWithAddress[] = await ethers.getSigners();

    const greeterDeployed = <Greeter>(
      await ethers.getContractAt("Greeter", "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3")
    );

    await greeterDeployed.connect(signers[0]).setGreeting(taskArguments.greeting);

    console.log("Greeting set: ", taskArguments.greeting);
  });
