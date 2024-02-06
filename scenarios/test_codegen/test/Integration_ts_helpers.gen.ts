/* TypeScript file generated from Integration_ts_helpers.res by genType. */
/* eslint-disable import/first */


// @ts-ignore: Implicit any on import
const Curry = require('rescript/lib/js/curry.js');

// @ts-ignore: Implicit any on import
const Integration_ts_helpersBS = require('./Integration_ts_helpers.bs');

import type {ethAddress as Ethers_ethAddress} from 'generated/src/bindings/Ethers.gen';

// tslint:disable-next-line:max-classes-per-file 
// tslint:disable-next-line:class-name
export abstract class chainConfig { protected opaque!: any }; /* simulate opaque types */

// tslint:disable-next-line:max-classes-per-file 
// tslint:disable-next-line:class-name
export abstract class chainManager { protected opaque!: any }; /* simulate opaque types */

export const getLocalChainConfig: (nftFactoryContractAddress:Ethers_ethAddress) => chainConfig = Integration_ts_helpersBS.getLocalChainConfig;

export const makeChainManager: (cfg:chainConfig) => chainManager = Integration_ts_helpersBS.makeChainManager;

export const startProcessing: (cfg:chainConfig, chainManager:chainManager) => void = function (Arg1: any, Arg2: any) {
  const result = Curry._2(Integration_ts_helpersBS.startProcessing, Arg1, Arg2);
  return result
};
