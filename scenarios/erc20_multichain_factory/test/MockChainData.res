module Indexer = {
  module ErrorHandling = ErrorHandling
  module Types = Types
  module Config = Config
  module Source = Source
  module FetchState = FetchState
  module ContractAddressingMap = ContractAddressingMap
}

include Helpers.ChainMocking.Make(Indexer)
