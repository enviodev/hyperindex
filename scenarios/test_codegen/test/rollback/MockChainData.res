module Indexer = {
  module Pino = Pino
  module Address = Address
  module ErrorHandling = ErrorHandling
  module Enums = Enums
  module Types = Types
  module Config = Config
  module Ethers = Ethers
  module Viem = Viem
  module HyperSyncClient = HyperSyncClient
  module ChainWorker = ChainWorker
  module ReorgDetection = ReorgDetection
  module FetchState = FetchState
  module ChainMap = ChainMap
  module ContractAddressingMap = ContractAddressingMap
}

include Helpers.ChainMocking.Make(Indexer)
