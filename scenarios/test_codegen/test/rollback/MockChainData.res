module Indexer = {
  module ErrorHandling = ErrorHandling
  module Types = Types
  module Config = Config
  module Source = Source
  module FetchState = FetchState
}

include Helpers.ChainMocking.Make(Indexer)
