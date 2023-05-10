"use strict";
var __awaiter = (this && this.__awaiter) || function (thisArg, _arguments, P, generator) {
    function adopt(value) { return value instanceof P ? value : new P(function (resolve) { resolve(value); }); }
    return new (P || (P = Promise))(function (resolve, reject) {
        function fulfilled(value) { try { step(generator.next(value)); } catch (e) { reject(e); } }
        function rejected(value) { try { step(generator["throw"](value)); } catch (e) { reject(e); } }
        function step(result) { result.done ? resolve(result.value) : adopt(result.value).then(fulfilled, rejected); }
        step((generator = generator.apply(thisArg, _arguments || [])).next());
    });
};
const { network, ethers } = require("hardhat");
let networkToUse = network.name;
module.exports = ({ getNamedAccounts, deployments }) => __awaiter(void 0, void 0, void 0, function* () {
    const provider = ethers.provider;
    const { deploy } = deployments;
    const accounts = yield ethers.getSigners();
    const deployer = accounts[0];
    const user1 = accounts[1];
    const user2 = accounts[2];
    const user3 = accounts[3];
    const user4 = accounts[4];
    console.log("deployer");
    console.log(deployer.address);
    const interestRate = 10;
    console.log("interest Rate set");
    let TreasuryContract = yield deploy("Treasury", {
        args: [interestRate],
        from: deployer.address,
        log: false,
    });
    console.log(`TreasuryContract deployed to ${TreasuryContract.address}`);
    let SimpleBankContract = yield deploy("SimpleBank", {
        args: [deployer.address],
        from: deployer.address,
        log: false,
    });
    console.log(" SimpleBank deployed to: ", SimpleBankContract.address);
    console.log("");
    console.log("Contract verification command");
    console.log("----------------------------------");
    console.log(`npx hardhat verify --network ${networkToUse} --contract contracts/SimpleBank.sol:SimpleBank ${SimpleBankContract.address}  `);
    console.log("");
});
module.exports.tags = ["deploy"];
