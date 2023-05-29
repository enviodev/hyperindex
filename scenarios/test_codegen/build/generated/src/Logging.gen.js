"use strict";
/* TypeScript file generated from Logging.res by genType. */
/* eslint-disable import/first */
Object.defineProperty(exports, "__esModule", { value: true });
exports.fatal = exports.error = exports.warn = exports.info = exports.debug = exports.trace = exports.log = exports.setLogLevel = void 0;
// @ts-ignore: Implicit any on import
const Curry = require('rescript/lib/js/curry.js');
// @ts-ignore: Implicit any on import
const LoggingBS = require('./Logging.bs');
exports.setLogLevel = LoggingBS.setLogLevel;
const log = function (Arg1, Arg2) {
    const result = Curry._2(LoggingBS.log, Arg1, Arg2);
    return result;
};
exports.log = log;
exports.trace = LoggingBS.trace;
exports.debug = LoggingBS.debug;
exports.info = LoggingBS.info;
exports.warn = LoggingBS.warn;
exports.error = LoggingBS.error;
exports.fatal = LoggingBS.fatal;
