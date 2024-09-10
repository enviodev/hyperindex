module Indexer = {
  module Pino = Pino
  module ErrorHandling = ErrorHandling
  module Address = Address
  module Types = Types
  module Config = Config
  module Ethers = Ethers
  module Viem = Viem
  module HyperSyncClient = HyperSyncClient
  module ChainWorker = ChainWorker
  module ReorgDetection = ReorgDetection
  module FetchState = FetchState
  module ChainMap = ChainMap
  module Enums = Enums
  module ContractAddressingMap = ContractAddressingMap
  module LogSelection = LogSelection
}

include Helpers.ChainMocking.Make(Indexer)
