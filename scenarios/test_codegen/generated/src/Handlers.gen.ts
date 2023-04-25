/* TypeScript file generated from Handlers.res by genType. */
/* eslint-disable import/first */


// @ts-ignore: Implicit any on import
const HandlersBS = require('./Handlers.bs');

import type {GravatarContract_NewGravatarEvent_context as Types_GravatarContract_NewGravatarEvent_context} from './Types.gen';

import type {GravatarContract_NewGravatarEvent_eventArgs as Types_GravatarContract_NewGravatarEvent_eventArgs} from './Types.gen';

import type {GravatarContract_TestEventEvent_context as Types_GravatarContract_TestEventEvent_context} from './Types.gen';

import type {GravatarContract_TestEventEvent_eventArgs as Types_GravatarContract_TestEventEvent_eventArgs} from './Types.gen';

import type {GravatarContract_UpdatedGravatarEvent_context as Types_GravatarContract_UpdatedGravatarEvent_context} from './Types.gen';

import type {GravatarContract_UpdatedGravatarEvent_eventArgs as Types_GravatarContract_UpdatedGravatarEvent_eventArgs} from './Types.gen';

import type {eventLog as Types_eventLog} from './Types.gen';

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
