require("hardhat-deploy");
require("@nomiclabs/hardhat-ethers");
require("hardhat-abi-exporter");
require("./tasks");
require("@nomicfoundation/hardhat-verify");

function getMnemonic(networkName) {
  if (networkName) {
    const mnemonic = process.env['MNEMONIC_' + networkName.toUpperCase()];
    if (mnemonic && mnemonic !== '') {
      return mnemonic;
    }
  }

  const mnemonic = process.env.MNEMONIC;
  if (!mnemonic || mnemonic === '') {
    return 'test test test test test test test test test test test junk';
  }
  return mnemonic;
}

function accounts(networkName) {
  return { mnemonic: getMnemonic(networkName) };
}

module.exports = {
  solidity: {
    version: "0.8.19",
  },
  defaultNetwork: "ganache",
  networks: {
    ganache: {
      url: "http://localhost:8545",
    },
    mumbai: {
      // url: "https://rpc.goerli.eth.gateway.fm",
      // url: "https://rpc.ankr.com/eth_goerli",
      url: "https://endpoints.omniatech.io/v1/eth/goerli/public",
      accounts: accounts('goerli'), // To specify this via mnemonic use `MNEMONIC_GOERLI="your mnemonic"`
    },
    goerli: {
      // url: "https://rpc.goerli.eth.gateway.fm",
      // url: "https://rpc.ankr.com/eth_goerli",
      url: "https://endpoints.omniatech.io/v1/eth/goerli/public",
      accounts: accounts('goerli'), // To specify this via mnemonic use `MNEMONIC_GOERLI="your mnemonic"`
    },
  },
  abiExporter: {
    path: "./abis",
    clear: true,
    flat: true,
    spacing: 2,
  },
  etherscan: {
    apiKey: {
      goerli: process.env.ETHERSCAN_KEY
    }
  }
};
