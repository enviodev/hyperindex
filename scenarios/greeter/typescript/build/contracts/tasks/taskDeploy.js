"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
const config_1 = require("hardhat/config");
(0, config_1.task)("task:deployGreeter")
    .addParam("greeting", "Say hello, be nice")
    .setAction(async function (taskArguments, { ethers }) {
    const signers = await ethers.getSigners();
    const greeterFactory = await ethers.getContractFactory("Greeter");
    const greeter = await greeterFactory.connect(signers[0]).deploy(taskArguments.greeting);
    await greeter.deployed();
    console.log("New greeter deployed to: ", greeter.address);
});
