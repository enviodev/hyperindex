require("hardhat-deploy");
require("@nomiclabs/hardhat-ethers");
// require("hardhat-abi-exporter");

require("./tasks");

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
  namedAccounts: {
    deployer: 0,
    admin: 1,
    user1: 2,
    user2: 3,
    user3: 4,
    user4: 5,
  },
  abiExporter: {
    path: "./abis",
    clear: true,
    flat: true,
    spacing: 2,
  }
};
