"use strict";
/* TypeScript file generated from Handlers.res by genType. */
/* eslint-disable import/first */
Object.defineProperty(exports, "__esModule", { value: true });
exports.SimpleNftContract_registerTransferHandler = exports.SimpleNftContract_registerTransferLoadEntities = exports.NftFactoryContract_registerSimpleNftCreatedHandler = exports.NftFactoryContract_registerSimpleNftCreatedLoadEntities = exports.GravatarContract_registerUpdatedGravatarHandler = exports.GravatarContract_registerNewGravatarHandler = exports.GravatarContract_registerTestEventHandler = exports.GravatarContract_registerUpdatedGravatarLoadEntities = exports.GravatarContract_registerNewGravatarLoadEntities = exports.GravatarContract_registerTestEventLoadEntities = void 0;
// @ts-ignore: Implicit any on import
const Curry = require('rescript/lib/js/curry.js');
// @ts-ignore: Implicit any on import
const HandlersBS = require('./Handlers.bs');
const GravatarContract_registerTestEventLoadEntities = function (Arg1) {
    const result = HandlersBS.GravatarContract.registerTestEventLoadEntities(function (Argevent, Argcontext) {
        const result1 = Arg1({ event: Argevent, context: { contractRegistration: Argcontext.contractRegistration, a: { testingALoad: function (Arg11, Arg2) {
                        const result2 = Curry._2(Argcontext.a.testingALoad, Arg11, Arg2.loaders);
                        return result2;
                    } } } });
        return result1;
    });
    return result;
};
exports.GravatarContract_registerTestEventLoadEntities = GravatarContract_registerTestEventLoadEntities;
const GravatarContract_registerNewGravatarLoadEntities = function (Arg1) {
    const result = HandlersBS.GravatarContract.registerNewGravatarLoadEntities(function (Argevent, Argcontext) {
        const result1 = Arg1({ event: Argevent, context: Argcontext });
        return result1;
    });
    return result;
};
exports.GravatarContract_registerNewGravatarLoadEntities = GravatarContract_registerNewGravatarLoadEntities;
const GravatarContract_registerUpdatedGravatarLoadEntities = function (Arg1) {
    const result = HandlersBS.GravatarContract.registerUpdatedGravatarLoadEntities(function (Argevent, Argcontext) {
        const result1 = Arg1({ event: Argevent, context: { contractRegistration: Argcontext.contractRegistration, gravatar: { gravatarWithChangesLoad: function (Arg11, Arg2) {
                        const result2 = Curry._2(Argcontext.gravatar.gravatarWithChangesLoad, Arg11, Arg2.loaders);
                        return result2;
                    } } } });
        return result1;
    });
    return result;
};
exports.GravatarContract_registerUpdatedGravatarLoadEntities = GravatarContract_registerUpdatedGravatarLoadEntities;
const GravatarContract_registerTestEventHandler = function (Arg1) {
    const result = HandlersBS.GravatarContract.registerTestEventHandler(function (Argevent, Argcontext) {
        const result1 = Arg1({ event: Argevent, context: Argcontext });
        return result1;
    });
    return result;
};
exports.GravatarContract_registerTestEventHandler = GravatarContract_registerTestEventHandler;
const GravatarContract_registerNewGravatarHandler = function (Arg1) {
    const result = HandlersBS.GravatarContract.registerNewGravatarHandler(function (Argevent, Argcontext) {
        const result1 = Arg1({ event: Argevent, context: Argcontext });
        return result1;
    });
    return result;
};
exports.GravatarContract_registerNewGravatarHandler = GravatarContract_registerNewGravatarHandler;
const GravatarContract_registerUpdatedGravatarHandler = function (Arg1) {
    const result = HandlersBS.GravatarContract.registerUpdatedGravatarHandler(function (Argevent, Argcontext) {
        const result1 = Arg1({ event: Argevent, context: Argcontext });
        return result1;
    });
    return result;
};
exports.GravatarContract_registerUpdatedGravatarHandler = GravatarContract_registerUpdatedGravatarHandler;
const NftFactoryContract_registerSimpleNftCreatedLoadEntities = function (Arg1) {
    const result = HandlersBS.NftFactoryContract.registerSimpleNftCreatedLoadEntities(function (Argevent, Argcontext) {
        const result1 = Arg1({ event: Argevent, context: Argcontext });
        return result1;
    });
    return result;
};
exports.NftFactoryContract_registerSimpleNftCreatedLoadEntities = NftFactoryContract_registerSimpleNftCreatedLoadEntities;
const NftFactoryContract_registerSimpleNftCreatedHandler = function (Arg1) {
    const result = HandlersBS.NftFactoryContract.registerSimpleNftCreatedHandler(function (Argevent, Argcontext) {
        const result1 = Arg1({ event: Argevent, context: Argcontext });
        return result1;
    });
    return result;
};
exports.NftFactoryContract_registerSimpleNftCreatedHandler = NftFactoryContract_registerSimpleNftCreatedHandler;
const SimpleNftContract_registerTransferLoadEntities = function (Arg1) {
    const result = HandlersBS.SimpleNftContract.registerTransferLoadEntities(function (Argevent, Argcontext) {
        const result1 = Arg1({ event: Argevent, context: { contractRegistration: Argcontext.contractRegistration, user: { userFromLoad: function (Arg11, Arg2) {
                        const result2 = Curry._2(Argcontext.user.userFromLoad, Arg11, Arg2.loaders);
                        return result2;
                    }, userToLoad: function (Arg12, Arg21) {
                        const result3 = Curry._2(Argcontext.user.userToLoad, Arg12, Arg21.loaders);
                        return result3;
                    } }, nftcollection: Argcontext.nftcollection, token: { existingTransferredTokenLoad: function (Arg13, Arg22) {
                        const result4 = Curry._2(Argcontext.token.existingTransferredTokenLoad, Arg13, Arg22.loaders);
                        return result4;
                    } } } });
        return result1;
    });
    return result;
};
exports.SimpleNftContract_registerTransferLoadEntities = SimpleNftContract_registerTransferLoadEntities;
const SimpleNftContract_registerTransferHandler = function (Arg1) {
    const result = HandlersBS.SimpleNftContract.registerTransferHandler(function (Argevent, Argcontext) {
        const result1 = Arg1({ event: Argevent, context: Argcontext });
        return result1;
    });
    return result;
};
exports.SimpleNftContract_registerTransferHandler = SimpleNftContract_registerTransferHandler;
