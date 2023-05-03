require("@nomicfoundation/hardhat-toolbox");
require("hardhat-abi-exporter");
require("hardhat-deploy");
require("@nomiclabs/hardhat-ethers");
require("./tasks");

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: {
    version: "0.8.19",
  },
  defaultNetwork: "ganache",
  networks: {
    ganache: {
      url: "http://localhost:8545",
    },
  },
  abiExporter: {
    path: "./abis",
    clear: true,
    flat: true,
    spacing: 2,
  },
};
