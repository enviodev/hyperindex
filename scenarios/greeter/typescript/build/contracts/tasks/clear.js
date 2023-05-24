"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
const config_1 = require("hardhat/config");
(0, config_1.task)("task:clearGreeting")
    .addParam("account", "Specify which account [0, 9]")
    .setAction(async function (taskArguments, hre) {
    let { ethers, deployments } = hre;
    let Greeter = await deployments.get("Greeter");
    const signers = await ethers.getSigners();
    const greeter = await ethers.getContractAt("Greeter", Greeter.address);
    await greeter.connect(signers[taskArguments.account]).clearGreeting();
    console.log("Greeting cleared ");
});
