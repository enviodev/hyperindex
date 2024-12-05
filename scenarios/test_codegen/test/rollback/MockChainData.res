module Indexer = {
  module ErrorHandling = ErrorHandling
  module Enums = Enums
  module Types = Types
  module Config = Config
  module HyperSyncClient = HyperSyncClient
  module ChainWorker = ChainWorker
  module ReorgDetection = ReorgDetection
  module FetchState = FetchState
  module ContractAddressingMap = ContractAddressingMap
  module LogSelection = LogSelection
}

include Helpers.ChainMocking.Make(Indexer)
