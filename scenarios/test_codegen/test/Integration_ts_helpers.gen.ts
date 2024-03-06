/* TypeScript file generated from Integration_ts_helpers.res by genType. */

/* eslint-disable */
/* tslint:disable */

const Integration_ts_helpersJS = require('./Integration_ts_helpers.bs.js');

import type {ethAddress as Ethers_ethAddress} from 'generated/src/bindings/Ethers.gen';

export abstract class chainConfig { protected opaque!: any }; /* simulate opaque types */

export abstract class chainManager { protected opaque!: any }; /* simulate opaque types */

export const getLocalChainConfig: (nftFactoryContractAddress:Ethers_ethAddress) => chainConfig = Integration_ts_helpersJS.getLocalChainConfig as any;

export const makeChainManager: (cfg:chainConfig) => chainManager = Integration_ts_helpersJS.makeChainManager as any;

export const startProcessing: (cfg:chainConfig, chainManager:chainManager) => void = Integration_ts_helpersJS.startProcessing as any;
