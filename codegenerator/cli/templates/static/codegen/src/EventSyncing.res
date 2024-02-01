// let startSyncingAllEvents = (~shouldSyncFromRawEvents: bool) => {
//   let chainManager: ChainManager.t = ChainManager.make(
//     ~configs=Config.config,
//     ~maxQueueSize=Env.maxEventFetchedQueueSize,
//     ~shouldSyncFromRawEvents,
//   )
//
//   Logging.info("Starting chain fetchers.")
//   chainManager->ChainManager.startFetchers
//
//   Logging.info("Starting main event processer.")
//
//   EventProcessing.startProcessingEventsOnQueue(~chainManager)
//   ->Js.Promise2.catch(err => {
//     Logging.error({
//       "err": err,
//       "msg": `EE600: We have hit a top level while error catcher processing events on the queue. Please notify the team on discord.`,
//     })->Js.Promise.resolve
//   })
//   ->ignore
// }

