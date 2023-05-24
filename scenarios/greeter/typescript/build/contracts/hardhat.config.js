"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
require("@nomicfoundation/hardhat-toolbox");
const dotenv_1 = require("dotenv");
require("hardhat-abi-exporter");
require("hardhat-deploy");
const path_1 = require("path");
require("./tasks/accounts");
require("./tasks/clear");
require("./tasks/greet");
const dotenvConfigPath = process.env.DOTENV_CONFIG_PATH || "./.env";
(0, dotenv_1.config)({ path: (0, path_1.resolve)(__dirname, dotenvConfigPath) });
// Ensure that we have all the environment variables we need.
const mnemonic = process.env.MNEMONIC;
if (!mnemonic) {
    throw new Error("Please set your MNEMONIC in a .env file");
}
const infuraApiKey = process.env.INFURA_API_KEY;
if (!infuraApiKey) {
    throw new Error("Please set your INFURA_API_KEY in a .env file");
}
const chainIds = {
    "arbitrum-mainnet": 42161,
    avalanche: 43114,
    bsc: 56,
    ganache: 1337,
    hardhat: 31337,
    mainnet: 1,
    "optimism-mainnet": 10,
    "polygon-mainnet": 137,
    "polygon-mumbai": 80001,
    sepolia: 11155111,
};
function getChainConfig(chain) {
    let jsonRpcUrl;
    switch (chain) {
        case "avalanche":
            jsonRpcUrl = "https://api.avax.network/ext/bc/C/rpc";
            break;
        case "bsc":
            jsonRpcUrl = "https://bsc-dataseed1.binance.org";
            break;
        default:
            jsonRpcUrl = "https://" + chain + ".infura.io/v3/" + infuraApiKey;
    }
    return {
        accounts: {
            count: 10,
            mnemonic,
            path: "m/44'/60'/0'/0",
        },
        chainId: chainIds[chain],
        url: jsonRpcUrl,
    };
}
const config = {
    defaultNetwork: "ganache",
    namedAccounts: {
        deployer: 0,
    },
    etherscan: {
        apiKey: {
            arbitrumOne: process.env.ARBISCAN_API_KEY || "",
            avalanche: process.env.SNOWTRACE_API_KEY || "",
            bsc: process.env.BSCSCAN_API_KEY || "",
            mainnet: process.env.ETHERSCAN_API_KEY || "",
            optimisticEthereum: process.env.OPTIMISM_API_KEY || "",
            polygon: process.env.POLYGONSCAN_API_KEY || "",
            polygonMumbai: process.env.POLYGONSCAN_API_KEY || "",
            sepolia: process.env.ETHERSCAN_API_KEY || "",
        },
    },
    gasReporter: {
        currency: "USD",
        enabled: process.env.REPORT_GAS ? true : false,
        excludeContracts: [],
        src: "./contracts",
    },
    networks: {
        hardhat: {
            accounts: {
                mnemonic,
            },
            chainId: chainIds.hardhat,
        },
        ganache: {
            accounts: {
                mnemonic, // this needs to match the mnenomic that has accounts with network tokens
            },
            chainId: chainIds.ganache,
            url: "http://localhost:8545",
        },
        arbitrum: getChainConfig("arbitrum-mainnet"),
        avalanche: getChainConfig("avalanche"),
        bsc: getChainConfig("bsc"),
        mainnet: getChainConfig("mainnet"),
        optimism: getChainConfig("optimism-mainnet"),
        "polygon-mainnet": getChainConfig("polygon-mainnet"),
        "polygon-mumbai": getChainConfig("polygon-mumbai"),
        sepolia: getChainConfig("sepolia"),
    },
    paths: {
        artifacts: "./artifacts",
        cache: "./cache",
        sources: "./contracts",
        tests: "./test",
    },
    solidity: {
        version: "0.8.17",
        settings: {
            metadata: {
                // Not including the metadata hash
                // https://github.com/paulrberg/hardhat-template/issues/31
                bytecodeHash: "none",
            },
            // Disable the optimizer when debugging
            // https://hardhat.org/hardhat-network/#solidity-optimizer-support
            optimizer: {
                enabled: true,
                runs: 800,
            },
        },
    },
    typechain: {
        outDir: "types",
        target: "ethers-v5",
    },
};
exports.default = config;
