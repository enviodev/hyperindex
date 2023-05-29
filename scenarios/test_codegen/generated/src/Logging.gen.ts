/* TypeScript file generated from Logging.res by genType. */
/* eslint-disable import/first */


// @ts-ignore: Implicit any on import
const Curry = require('rescript/lib/js/curry.js');

// @ts-ignore: Implicit any on import
const LoggingBS = require('./Logging.bs');

import type {logLevel as Config_logLevel} from './Config.gen';

export const setLogLevel: (level:Config_logLevel) => void = LoggingBS.setLogLevel;

export const log: <T1>(level:Config_logLevel, message:T1) => void = function <T1>(Arg1: any, Arg2: any) {
  const result = Curry._2(LoggingBS.log, Arg1, Arg2);
  return result
};

export const trace: <T1>(message:T1) => void = LoggingBS.trace;

export const debug: <T1>(message:T1) => void = LoggingBS.debug;

export const info: <T1>(message:T1) => void = LoggingBS.info;

export const warn: <T1>(message:T1) => void = LoggingBS.warn;

export const error: <T1>(message:T1) => void = LoggingBS.error;

export const fatal: <T1>(message:T1) => void = LoggingBS.fatal;
