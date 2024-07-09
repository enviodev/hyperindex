module Indexer = {
  module Enums = Enums
  module Types = Types
  module Config = Config
  module Ethers = Ethers
  module ChainWorkerTypes = ChainWorkerTypes
  module ReorgDetection = ReorgDetection
  module FetchState = FetchState
  module ChainMap = ChainMap
  module ContractAddressingMap = ContractAddressingMap
}

include Helpers.ChainMocking.Make(Indexer)
