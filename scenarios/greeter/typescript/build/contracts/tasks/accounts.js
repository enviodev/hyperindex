"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
const config_1 = require("hardhat/config");
(0, config_1.task)("accounts", "Prints the list of accounts", async (_taskArgs, hre) => {
    const accounts = await hre.ethers.getSigners();
    for (const account of accounts) {
        console.log(await account.getAddress());
    }
});
