import "@nomiclabs/hardhat-ethers";
import "hardhat-deploy";
import { HardhatUserConfig } from "hardhat/config";

import "hardhat-abi-exporter";
import { AbiExporterUserConfig } from "hardhat-abi-exporter";

import "@typechain/hardhat";
import "./contracts/tasks";
import { TypechainUserConfig } from "@typechain/hardhat/dist/types";

let secertsConfig;
try {
  secertsConfig = require("./contracts/secretsManager.ts");
} catch (e) {
  console.error(
    "You are using the example secrets manager, please copy this file if you want to use it"
  );
  secertsConfig = require("./contracts/secretsManager.example.ts");
}

const { mnemonic } = secertsConfig;
let typeChainConfig: TypechainUserConfig = {
  target: "ethers-v6",
};

const abiExporter: AbiExporterUserConfig = {
  path: "./abis",
  clear: true,
  flat: true,
  spacing: 2,
};

const config: HardhatUserConfig = {
  solidity: "0.8.19",
  paths: {
    root: "contracts",
  },
  typechain: typeChainConfig,
  abiExporter: abiExporter,
  networks: {
    hardhat: {
      accounts: {
        mnemonic: "test test test test test test test test test test test test",
      },
    },
    ganache: {
      url: "http://0.0.0.0:8545",
      chainId: 1337,
    },
    localhost: {
      url: "http://127.0.0.1:8545",
      chainId: 1337,
      accounts: {
        mnemonic: "test test test test test test test test test test test test",
      },
    },
    fuji: {
      url: "https://api.avax-test.network/ext/bc/C/rpc",
      gasPrice: 225000000000,
      chainId: 43113,
      accounts: { mnemonic },
    },
  },
};

export default config;
