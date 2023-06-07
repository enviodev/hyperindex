/* TypeScript file generated from Handlers.res by genType. */
/* eslint-disable import/first */


// @ts-ignore: Implicit any on import
const Curry = require('rescript/lib/js/curry.js');

// @ts-ignore: Implicit any on import
const HandlersBS = require('./Handlers.bs');

import type {GravatarContract_NewGravatarEvent_context as Types_GravatarContract_NewGravatarEvent_context} from './Types.gen';

import type {GravatarContract_NewGravatarEvent_eventArgs as Types_GravatarContract_NewGravatarEvent_eventArgs} from './Types.gen';

import type {GravatarContract_NewGravatarEvent_loaderContext as Types_GravatarContract_NewGravatarEvent_loaderContext} from './Types.gen';

import type {GravatarContract_TestEventEvent_context as Types_GravatarContract_TestEventEvent_context} from './Types.gen';

import type {GravatarContract_TestEventEvent_eventArgs as Types_GravatarContract_TestEventEvent_eventArgs} from './Types.gen';

import type {GravatarContract_TestEventEvent_loaderContext as Types_GravatarContract_TestEventEvent_loaderContext} from './Types.gen';

import type {GravatarContract_UpdatedGravatarEvent_context as Types_GravatarContract_UpdatedGravatarEvent_context} from './Types.gen';

import type {GravatarContract_UpdatedGravatarEvent_eventArgs as Types_GravatarContract_UpdatedGravatarEvent_eventArgs} from './Types.gen';

import type {GravatarContract_UpdatedGravatarEvent_loaderContext as Types_GravatarContract_UpdatedGravatarEvent_loaderContext} from './Types.gen';

import type {NftFactoryContract_SimpleNftCreatedEvent_context as Types_NftFactoryContract_SimpleNftCreatedEvent_context} from './Types.gen';

import type {NftFactoryContract_SimpleNftCreatedEvent_eventArgs as Types_NftFactoryContract_SimpleNftCreatedEvent_eventArgs} from './Types.gen';

import type {NftFactoryContract_SimpleNftCreatedEvent_loaderContext as Types_NftFactoryContract_SimpleNftCreatedEvent_loaderContext} from './Types.gen';

import type {SimpleNftContract_TransferEvent_context as Types_SimpleNftContract_TransferEvent_context} from './Types.gen';

import type {SimpleNftContract_TransferEvent_eventArgs as Types_SimpleNftContract_TransferEvent_eventArgs} from './Types.gen';

import type {SimpleNftContract_TransferEvent_loaderContext as Types_SimpleNftContract_TransferEvent_loaderContext} from './Types.gen';

import type {eventLog as Types_eventLog} from './Types.gen';

export const GravatarContract_registerTestEventLoadEntities: (handler:((_1:{ readonly event: Types_eventLog<Types_GravatarContract_TestEventEvent_eventArgs>; readonly context: Types_GravatarContract_TestEventEvent_loaderContext }) => void)) => void = function (Arg1: any) {
  const result = HandlersBS.GravatarContract.registerTestEventLoadEntities(function (Argevent: any, Argcontext: any) {
      const result1 = Arg1({event:Argevent, context:{contractRegistration:Argcontext.contractRegistration, a:{testingALoad:function (Arg11: any, Arg2: any) {
          const result2 = Curry._2(Argcontext.a.testingALoad, Arg11, Arg2.loaders);
          return result2
        }}}});
      return result1
    });
  return result
};

export const GravatarContract_registerNewGravatarLoadEntities: (handler:((_1:{ readonly event: Types_eventLog<Types_GravatarContract_NewGravatarEvent_eventArgs>; readonly context: Types_GravatarContract_NewGravatarEvent_loaderContext }) => void)) => void = function (Arg1: any) {
  const result = HandlersBS.GravatarContract.registerNewGravatarLoadEntities(function (Argevent: any, Argcontext: any) {
      const result1 = Arg1({event:Argevent, context:Argcontext});
      return result1
    });
  return result
};

export const GravatarContract_registerUpdatedGravatarLoadEntities: (handler:((_1:{ readonly event: Types_eventLog<Types_GravatarContract_UpdatedGravatarEvent_eventArgs>; readonly context: Types_GravatarContract_UpdatedGravatarEvent_loaderContext }) => void)) => void = function (Arg1: any) {
  const result = HandlersBS.GravatarContract.registerUpdatedGravatarLoadEntities(function (Argevent: any, Argcontext: any) {
      const result1 = Arg1({event:Argevent, context:{contractRegistration:Argcontext.contractRegistration, gravatar:{gravatarWithChangesLoad:function (Arg11: any, Arg2: any) {
          const result2 = Curry._2(Argcontext.gravatar.gravatarWithChangesLoad, Arg11, Arg2.loaders);
          return result2
        }}}});
      return result1
    });
  return result
};

export const GravatarContract_registerTestEventHandler: (handler:((_1:{ readonly event: Types_eventLog<Types_GravatarContract_TestEventEvent_eventArgs>; readonly context: Types_GravatarContract_TestEventEvent_context }) => void)) => void = function (Arg1: any) {
  const result = HandlersBS.GravatarContract.registerTestEventHandler(function (Argevent: any, Argcontext: any) {
      const result1 = Arg1({event:Argevent, context:Argcontext});
      return result1
    });
  return result
};

export const GravatarContract_registerNewGravatarHandler: (handler:((_1:{ readonly event: Types_eventLog<Types_GravatarContract_NewGravatarEvent_eventArgs>; readonly context: Types_GravatarContract_NewGravatarEvent_context }) => void)) => void = function (Arg1: any) {
  const result = HandlersBS.GravatarContract.registerNewGravatarHandler(function (Argevent: any, Argcontext: any) {
      const result1 = Arg1({event:Argevent, context:Argcontext});
      return result1
    });
  return result
};

export const GravatarContract_registerUpdatedGravatarHandler: (handler:((_1:{ readonly event: Types_eventLog<Types_GravatarContract_UpdatedGravatarEvent_eventArgs>; readonly context: Types_GravatarContract_UpdatedGravatarEvent_context }) => void)) => void = function (Arg1: any) {
  const result = HandlersBS.GravatarContract.registerUpdatedGravatarHandler(function (Argevent: any, Argcontext: any) {
      const result1 = Arg1({event:Argevent, context:Argcontext});
      return result1
    });
  return result
};

export const NftFactoryContract_registerSimpleNftCreatedLoadEntities: (handler:((_1:{ readonly event: Types_eventLog<Types_NftFactoryContract_SimpleNftCreatedEvent_eventArgs>; readonly context: Types_NftFactoryContract_SimpleNftCreatedEvent_loaderContext }) => void)) => void = function (Arg1: any) {
  const result = HandlersBS.NftFactoryContract.registerSimpleNftCreatedLoadEntities(function (Argevent: any, Argcontext: any) {
      const result1 = Arg1({event:Argevent, context:Argcontext});
      return result1
    });
  return result
};

export const NftFactoryContract_registerSimpleNftCreatedHandler: (handler:((_1:{ readonly event: Types_eventLog<Types_NftFactoryContract_SimpleNftCreatedEvent_eventArgs>; readonly context: Types_NftFactoryContract_SimpleNftCreatedEvent_context }) => void)) => void = function (Arg1: any) {
  const result = HandlersBS.NftFactoryContract.registerSimpleNftCreatedHandler(function (Argevent: any, Argcontext: any) {
      const result1 = Arg1({event:Argevent, context:Argcontext});
      return result1
    });
  return result
};

export const SimpleNftContract_registerTransferLoadEntities: (handler:((_1:{ readonly event: Types_eventLog<Types_SimpleNftContract_TransferEvent_eventArgs>; readonly context: Types_SimpleNftContract_TransferEvent_loaderContext }) => void)) => void = function (Arg1: any) {
  const result = HandlersBS.SimpleNftContract.registerTransferLoadEntities(function (Argevent: any, Argcontext: any) {
      const result1 = Arg1({event:Argevent, context:{contractRegistration:Argcontext.contractRegistration, user:{userFromLoad:function (Arg11: any, Arg2: any) {
          const result2 = Curry._2(Argcontext.user.userFromLoad, Arg11, Arg2.loaders);
          return result2
        }, userToLoad:function (Arg12: any, Arg21: any) {
          const result3 = Curry._2(Argcontext.user.userToLoad, Arg12, Arg21.loaders);
          return result3
        }}, nftcollection:Argcontext.nftcollection, token:{existingTransferredTokenLoad:function (Arg13: any, Arg22: any) {
          const result4 = Curry._2(Argcontext.token.existingTransferredTokenLoad, Arg13, Arg22.loaders);
          return result4
        }}}});
      return result1
    });
  return result
};

export const SimpleNftContract_registerTransferHandler: (handler:((_1:{ readonly event: Types_eventLog<Types_SimpleNftContract_TransferEvent_eventArgs>; readonly context: Types_SimpleNftContract_TransferEvent_context }) => void)) => void = function (Arg1: any) {
  const result = HandlersBS.SimpleNftContract.registerTransferHandler(function (Argevent: any, Argcontext: any) {
      const result1 = Arg1({event:Argevent, context:Argcontext});
      return result1
    });
  return result
};
