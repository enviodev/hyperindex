module Indexer = {
  module ErrorHandling = ErrorHandling
  module Types = Types
  module Config = Config
  module ChainWorker = ChainWorker
  module FetchState = FetchState
  module ContractAddressingMap = ContractAddressingMap
}

include Helpers.ChainMocking.Make(Indexer)
