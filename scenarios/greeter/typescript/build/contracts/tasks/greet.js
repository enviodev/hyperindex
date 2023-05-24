"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
const config_1 = require("hardhat/config");
(0, config_1.task)("task:setGreeting")
    .addParam("greeting", "Say hello, be nice")
    .addParam("account", "Specify which account [0, 9]")
    .setAction(async function (taskArguments, hre) {
    let { ethers, deployments } = hre;
    let Greeter = await deployments.get("Greeter");
    const signers = await ethers.getSigners();
    const greeter = await ethers.getContractAt("Greeter", Greeter.address);
    await greeter.connect(signers[taskArguments.account]).setGreeting(taskArguments.greeting);
    console.log("Greeting set: ", taskArguments.greeting);
});
