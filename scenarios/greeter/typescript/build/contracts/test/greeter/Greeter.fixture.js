"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.deployGreeterFixture = void 0;
const hardhat_1 = require("hardhat");
async function deployGreeterFixture() {
    const signers = await hardhat_1.ethers.getSigners();
    const admin = signers[0];
    const greeting = "Hello, world!";
    const greeterFactory = await hardhat_1.ethers.getContractFactory("Greeter");
    const greeter = await greeterFactory.connect(admin).deploy(greeting);
    await greeter.deployed();
    return { greeter };
}
exports.deployGreeterFixture = deployGreeterFixture;
