// Generated by ReScript, PLEASE EDIT WITH CARE
'use strict';

var Curry = require("rescript/lib/js/curry.js");
var Ethers = require("generated/src/bindings/Ethers.bs.js");
var Handlers = require("generated/src/Handlers.bs.js");

Handlers.ERC20Contract.registerCreationLoadEntities(function ($$event, context) {
      Curry._1(context.tokens.tokensCreationLoad, $$event.srcAddress);
    });

Handlers.ERC20Contract.registerCreationHandler(function ($$event, context) {
      var tokenObject_id = $$event.srcAddress;
      var tokenObject_name = $$event.params.name;
      var tokenObject_symbol = $$event.params.symbol;
      var tokenObject = {
        id: tokenObject_id,
        name: tokenObject_name,
        symbol: tokenObject_symbol,
        decimals: 18
      };
      Curry._1(context.tokens.insert, tokenObject);
      Curry._1(context.totals.insert, {
            id: $$event.srcAddress,
            erc20: tokenObject_id,
            totalTransfer: BigInt(0)
          });
    });

Handlers.ERC20Contract.registerTransferLoadEntities(function ($$event, context) {
      Curry._1(context.totals.totalChangesLoad, $$event.srcAddress);
    });

Handlers.ERC20Contract.registerTransferHandler(function ($$event, context) {
      var currentTotals = Curry._1(context.totals.totalChanges, undefined);
      if (currentTotals !== undefined) {
        return Curry._1(context.totals.update, {
                    id: $$event.srcAddress,
                    erc20: currentTotals.erc20,
                    totalTransfer: Ethers.$$BigInt.add(currentTotals.totalTransfer, $$event.params.value)
                  });
      }
      
    });

/*  Not a pure module */
