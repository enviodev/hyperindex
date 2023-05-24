"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
const func = async function (hre) {
    const { deployer } = await hre.getNamedAccounts();
    const { deploy } = hre.deployments;
    const greeter = await deploy("Greeter", {
        from: deployer,
        args: ["Bonjour, le monde!"],
        log: true,
        autoMine: true, // speed up deployment on local network (ganache, hardhat), no effect on live networks
    });
    console.log(`Greeter contract: `, greeter.address);
};
exports.default = func;
func.id = "deploy_greeter"; // id required to prevent reexecution
func.tags = ["Greeter"];
