/*
*Please refer to https://docs.envio.dev for a thorough guide on all Envio indexer features*
*/

let { MyAwesomeContractContract } = require("../generated/src/Handlers.bs.js");

MyAwesomeContractContract.AwesomeEvent.loader(({ event, context }) => {
  let _ = context.awesomeEvent.load(event.params.identifier);
});

MyAwesomeContractContract.AwesomeEvent.handler(({ event, context }) => {
  let awesomeEventObject = context.awesomeEvent.get(event.params.identifier);
  context.awesomeEvent.set(awesomeEventObject);
});
