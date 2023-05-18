require("hardhat-deploy");
require("@nomiclabs/hardhat-ethers");
require("hardhat-abi-exporter");

require("./tasks");

let config;
try {
  config = require("./secretsManager.js");
} catch (e) {
  console.error(
    "You are using the example secrets manager, please copy this file if you want to use it"
  );
  config = require("./secretsManager.example.js");
}

const {
  mnemonic,
} = config;

module.exports = {
  solidity: {
    version: "0.8.19",
  },
  defaultNetwork: "ganache",
  networks: {
    ganache: {
      url: "http://0.0.0.0:8545",
    },
    fuji: {
      url: 'https://api.avax-test.network/ext/bc/C/rpc',
      gasPrice: 225000000000,
      chainId: 43113,
      accounts: { mnemonic },
    },
  },
  abiExporter: {
    path: "./abis",
    clear: true,
    flat: true,
    spacing: 2,
  },
};
