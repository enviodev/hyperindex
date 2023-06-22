"use strict";
/* TypeScript file generated from Logging.res by genType. */
/* eslint-disable import/first */
Object.defineProperty(exports, "__esModule", { value: true });
exports.fatal = exports.error = exports.warn = exports.info = exports.debug = exports.trace = exports.setLogLevel = void 0;
// @ts-ignore: Implicit any on import
const LoggingBS = require('./Logging.bs');
exports.setLogLevel = LoggingBS.setLogLevel;
exports.trace = LoggingBS.trace;
exports.debug = LoggingBS.debug;
exports.info = LoggingBS.info;
exports.warn = LoggingBS.warn;
exports.error = LoggingBS.error;
exports.fatal = LoggingBS.fatal;
