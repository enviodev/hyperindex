let runUpMigrations = async (~reset=false) => {
  let config = Config.load()
  let persistence = PgStorage.makePersistenceFromConfig(~config)
  await persistence->Persistence.init(~reset, ~chainConfigs=config.chainMap->ChainMap.values)
}

let runDownMigrations = async () => {
  let config = Config.load()
  let persistence = PgStorage.makePersistenceFromConfig(~config)
  await persistence.storage.reset()
}
