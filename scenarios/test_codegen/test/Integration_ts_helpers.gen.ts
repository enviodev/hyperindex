/* TypeScript file generated from Integration_ts_helpers.res by genType. */

/* eslint-disable */
/* tslint:disable */

import * as Integration_ts_helpersJS from './Integration_ts_helpers.res.mjs';

import type {t as Address_t} from 'envio/src/Address.gen.js';

export abstract class chainConfig { protected opaque!: any }; /* simulate opaque types */

export abstract class chainManager { protected opaque!: any }; /* simulate opaque types */

export const getLocalChainConfig: (nftFactoryContractAddress:Address_t) => chainConfig = Integration_ts_helpersJS.getLocalChainConfig as any;

export const makeChainManager: (cfg:chainConfig) => chainManager = Integration_ts_helpersJS.makeChainManager as any;

export const startProcessing: <T1>(_config:T1, _cfg:chainConfig, _chainManager:chainManager) => void = Integration_ts_helpersJS.startProcessing as any;
