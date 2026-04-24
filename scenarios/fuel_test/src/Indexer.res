//*************
//**CONTRACTS**
//*************

module Transaction = {
  type t = {
    id: string,
}
}

module Block = {
  type t = {
    id: string,
    height: int,
    time: int,
}
}

module SingleOrMultiple: {
  type t<'a>
  let normalizeOrThrow: (t<'a>, ~nestedArrayDepth: int=?) => array<'a>
  let single: 'a => t<'a>
  let multiple: array<'a> => t<'a>
} = {
  type t<'a> = JSON.t

  external single: 'a => t<'a> = "%identity"
  external multiple: array<'a> => t<'a> = "%identity"
  external castMultiple: t<'a> => array<'a> = "%identity"
  external castSingle: t<'a> => 'a = "%identity"

  exception AmbiguousEmptyNestedArray

  let rec isMultiple = (t: t<'a>, ~nestedArrayDepth): bool =>
    if !Array.isArray(t) {
      false
    } else {
      let arr = t->(Utils.magic: t<'a> => array<t<'a>>)
      if nestedArrayDepth == 0 {
        true
      } else if arr->Array.length == 0 {
        AmbiguousEmptyNestedArray->ErrorHandling.mkLogAndRaise(
          ~msg="The given empty array could be interpreted as a flat array (value) or nested array. Since it's ambiguous,
          please pass in a nested empty array if the intention is to provide an empty array as a value",
        )
      } else {
        arr->Utils.Array.firstUnsafe->isMultiple(~nestedArrayDepth=nestedArrayDepth - 1)
      }
    }

  let normalizeOrThrow = (t: t<'a>, ~nestedArrayDepth=0): array<'a> => {
    if t->isMultiple(~nestedArrayDepth) {
      t->castMultiple
    } else {
      [t->castSingle]
    }
  }
}

/** Options for onEvent / contractRegister. */
type onEventOptions<'eventIdentity, 'where> = {
  event: 'eventIdentity,
  wildcard?: bool,
  where?: 'where,
}

module Enums = {

}

module Entities = {
  type id = string

  module User = {
    type t = {id: id, greetings: array<string>, latestGreeting: string, numberOfGreetings: int}

    type getWhereFilter = {@as("id") id?: Envio.whereOperator<id>, @as("greetings") greetings?: Envio.whereOperator<array<string>>, @as("latestGreeting") latestGreeting?: Envio.whereOperator<string>, @as("numberOfGreetings") numberOfGreetings?: Envio.whereOperator<int>}
  }

  type rec name<'entity> =
    | @as("User") User: name<User.t>
}

type handlerEntityOperations<'entity, 'getWhereFilter> = {
  get: string => promise<option<'entity>>,
  getOrThrow: (string, ~message: string=?) => promise<'entity>,
  getWhere: 'getWhereFilter => promise<array<'entity>>,
  getOrCreate: 'entity => promise<'entity>,
  set: 'entity => unit,
  deleteUnsafe: string => unit,
}

type handlerContext = {
  log: Envio.logger,
  effect: 'input 'output. (Envio.effect<'input, 'output>, 'input) => promise<'output>,
  isPreload: bool,
  chain: Internal.chainInfo,
  \"User": handlerEntityOperations<Entities.User.t, Entities.User.getWhereFilter>,
}

type chainId = [#0]

type contractRegisterContract = { add: Address.t => unit }

type contractRegisterChain = {
  id: chainId,
  \"AllEvents": contractRegisterContract,
  \"Greeter": contractRegisterContract,
}

type contractRegisterContext = {
  log: Envio.logger,
  chain: contractRegisterChain,
}

module AllEvents = {
let abi = FuelSDK.transpileAbi((await Utils.importPathWithJson(`../abis/all-events-abi.json`))["default"])
/*Silence warning of label defined in multiple types*/
@@warning("-30")
type rec type0 = (type27, type22)
 and type1 = array<type28>
 @tag("case") and type2 = | Pending({payload: type20}) | Completed({payload: type26}) | Failed({payload: type11})
 @tag("case") and type3 = | Address({payload: type13}) | ContractId({payload: type16})
 @tag("case") and type4<'t> = | None({payload: type20}) | Some({payload: 't})
 @tag("case") and type5<'t, 'e> = | Ok({payload: 't}) | Err({payload: 'e})
 and type8 = bigint
 and type9 = {f1: type26}
 and type10 = {f1: type26, f2: type4<type26>}
 and type11 = {reason: type26}
 and type12 = {tags: type4<type19<type17>>}
 and type13 = {bits: type21}
 and type14 = unknown
 and type15 = {ptr: type8, cap: type27}
 and type16 = {bits: type21}
 and type17 = string
 and type18<'t> = {ptr: type8, cap: type27}
 and type19<'t> = array<'t>
 and type20 = unit
 and type21 = string
 and type22 = bool
 and type23 = string
 and type24 = int
 and type25 = bigint
 and type26 = int
 and type27 = bigint
 and type28 = int
@@warning("+30")
let contractName = "AllEvents"

  module UnitLog = {

    let name = "UnitLog"
    let contractName = contractName
    type params = type20
    /** Event params with all fields optional. Missing fields use default values. */
    type paramsConstructor = type20
    type block = Block.t
    type transaction = Transaction.t

    type event = {
      /** The name of the contract that emitted this event. */
      contractName: string,
      /** The name of the event. */
      eventName: string,
      /** The parameters or arguments associated with this event. */
      params: params,
      /** The unique identifier of the blockchain network where this event occurred. */
      chainId: chainId,
      /** The address of the contract that emitted this event. */
      srcAddress: Address.t,
      /** The index of this event's log within the block. */
      logIndex: int,
      /** The transaction that triggered this event. Configurable in `config.yaml` via the `field_selection` option. */
      transaction: transaction,
      /** The block in which this event was recorded. Configurable in `config.yaml` via the `field_selection` option. */
      block: block,
    }

    type whereParams = {}

    type onEventWhere = Internal.noOnEventWhere
  }

  module Option_ = {

    let name = "Option_"
    let contractName = contractName
    type params = type4<type26>
    /** Event params with all fields optional. Missing fields use default values. */
    type paramsConstructor = type4<type26>
    type block = Block.t
    type transaction = Transaction.t

    type event = {
      /** The name of the contract that emitted this event. */
      contractName: string,
      /** The name of the event. */
      eventName: string,
      /** The parameters or arguments associated with this event. */
      params: params,
      /** The unique identifier of the blockchain network where this event occurred. */
      chainId: chainId,
      /** The address of the contract that emitted this event. */
      srcAddress: Address.t,
      /** The index of this event's log within the block. */
      logIndex: int,
      /** The transaction that triggered this event. Configurable in `config.yaml` via the `field_selection` option. */
      transaction: transaction,
      /** The block in which this event was recorded. Configurable in `config.yaml` via the `field_selection` option. */
      block: block,
    }

    type whereParams = {}

    type onEventWhere = Internal.noOnEventWhere
  }

  module SimpleStructWithOptionalField = {

    let name = "SimpleStructWithOptionalField"
    let contractName = contractName
    type params = type10
    /** Event params with all fields optional. Missing fields use default values. */
    type paramsConstructor = type10
    type block = Block.t
    type transaction = Transaction.t

    type event = {
      /** The name of the contract that emitted this event. */
      contractName: string,
      /** The name of the event. */
      eventName: string,
      /** The parameters or arguments associated with this event. */
      params: params,
      /** The unique identifier of the blockchain network where this event occurred. */
      chainId: chainId,
      /** The address of the contract that emitted this event. */
      srcAddress: Address.t,
      /** The index of this event's log within the block. */
      logIndex: int,
      /** The transaction that triggered this event. Configurable in `config.yaml` via the `field_selection` option. */
      transaction: transaction,
      /** The block in which this event was recorded. Configurable in `config.yaml` via the `field_selection` option. */
      block: block,
    }

    type whereParams = {}

    type onEventWhere = Internal.noOnEventWhere
  }

  module U8Log = {

    let name = "U8Log"
    let contractName = contractName
    type params = type28
    /** Event params with all fields optional. Missing fields use default values. */
    type paramsConstructor = type28
    type block = Block.t
    type transaction = Transaction.t

    type event = {
      /** The name of the contract that emitted this event. */
      contractName: string,
      /** The name of the event. */
      eventName: string,
      /** The parameters or arguments associated with this event. */
      params: params,
      /** The unique identifier of the blockchain network where this event occurred. */
      chainId: chainId,
      /** The address of the contract that emitted this event. */
      srcAddress: Address.t,
      /** The index of this event's log within the block. */
      logIndex: int,
      /** The transaction that triggered this event. Configurable in `config.yaml` via the `field_selection` option. */
      transaction: transaction,
      /** The block in which this event was recorded. Configurable in `config.yaml` via the `field_selection` option. */
      block: block,
    }

    type whereParams = {}

    type onEventWhere = Internal.noOnEventWhere
  }

  module ArrayLog = {

    let name = "ArrayLog"
    let contractName = contractName
    type params = type1
    /** Event params with all fields optional. Missing fields use default values. */
    type paramsConstructor = type1
    type block = Block.t
    type transaction = Transaction.t

    type event = {
      /** The name of the contract that emitted this event. */
      contractName: string,
      /** The name of the event. */
      eventName: string,
      /** The parameters or arguments associated with this event. */
      params: params,
      /** The unique identifier of the blockchain network where this event occurred. */
      chainId: chainId,
      /** The address of the contract that emitted this event. */
      srcAddress: Address.t,
      /** The index of this event's log within the block. */
      logIndex: int,
      /** The transaction that triggered this event. Configurable in `config.yaml` via the `field_selection` option. */
      transaction: transaction,
      /** The block in which this event was recorded. Configurable in `config.yaml` via the `field_selection` option. */
      block: block,
    }

    type whereParams = {}

    type onEventWhere = Internal.noOnEventWhere
  }

  module Result = {

    let name = "Result"
    let contractName = contractName
    type params = type5<type26, type22>
    /** Event params with all fields optional. Missing fields use default values. */
    type paramsConstructor = type5<type26, type22>
    type block = Block.t
    type transaction = Transaction.t

    type event = {
      /** The name of the contract that emitted this event. */
      contractName: string,
      /** The name of the event. */
      eventName: string,
      /** The parameters or arguments associated with this event. */
      params: params,
      /** The unique identifier of the blockchain network where this event occurred. */
      chainId: chainId,
      /** The address of the contract that emitted this event. */
      srcAddress: Address.t,
      /** The index of this event's log within the block. */
      logIndex: int,
      /** The transaction that triggered this event. Configurable in `config.yaml` via the `field_selection` option. */
      transaction: transaction,
      /** The block in which this event was recorded. Configurable in `config.yaml` via the `field_selection` option. */
      block: block,
    }

    type whereParams = {}

    type onEventWhere = Internal.noOnEventWhere
  }

  module U64Log = {

    let name = "U64Log"
    let contractName = contractName
    type params = type27
    /** Event params with all fields optional. Missing fields use default values. */
    type paramsConstructor = type27
    type block = Block.t
    type transaction = Transaction.t

    type event = {
      /** The name of the contract that emitted this event. */
      contractName: string,
      /** The name of the event. */
      eventName: string,
      /** The parameters or arguments associated with this event. */
      params: params,
      /** The unique identifier of the blockchain network where this event occurred. */
      chainId: chainId,
      /** The address of the contract that emitted this event. */
      srcAddress: Address.t,
      /** The index of this event's log within the block. */
      logIndex: int,
      /** The transaction that triggered this event. Configurable in `config.yaml` via the `field_selection` option. */
      transaction: transaction,
      /** The block in which this event was recorded. Configurable in `config.yaml` via the `field_selection` option. */
      block: block,
    }

    type whereParams = {}

    type onEventWhere = Internal.noOnEventWhere
  }

  module B256Log = {

    let name = "B256Log"
    let contractName = contractName
    type params = type21
    /** Event params with all fields optional. Missing fields use default values. */
    type paramsConstructor = type21
    type block = Block.t
    type transaction = Transaction.t

    type event = {
      /** The name of the contract that emitted this event. */
      contractName: string,
      /** The name of the event. */
      eventName: string,
      /** The parameters or arguments associated with this event. */
      params: params,
      /** The unique identifier of the blockchain network where this event occurred. */
      chainId: chainId,
      /** The address of the contract that emitted this event. */
      srcAddress: Address.t,
      /** The index of this event's log within the block. */
      logIndex: int,
      /** The transaction that triggered this event. Configurable in `config.yaml` via the `field_selection` option. */
      transaction: transaction,
      /** The block in which this event was recorded. Configurable in `config.yaml` via the `field_selection` option. */
      block: block,
    }

    type whereParams = {}

    type onEventWhere = Internal.noOnEventWhere
  }

  module U32Log = {

    let name = "U32Log"
    let contractName = contractName
    type params = type26
    /** Event params with all fields optional. Missing fields use default values. */
    type paramsConstructor = type26
    type block = Block.t
    type transaction = Transaction.t

    type event = {
      /** The name of the contract that emitted this event. */
      contractName: string,
      /** The name of the event. */
      eventName: string,
      /** The parameters or arguments associated with this event. */
      params: params,
      /** The unique identifier of the blockchain network where this event occurred. */
      chainId: chainId,
      /** The address of the contract that emitted this event. */
      srcAddress: Address.t,
      /** The index of this event's log within the block. */
      logIndex: int,
      /** The transaction that triggered this event. Configurable in `config.yaml` via the `field_selection` option. */
      transaction: transaction,
      /** The block in which this event was recorded. Configurable in `config.yaml` via the `field_selection` option. */
      block: block,
    }

    type whereParams = {}

    type onEventWhere = Internal.noOnEventWhere
  }

  module Status = {

    let name = "Status"
    let contractName = contractName
    type params = type2
    /** Event params with all fields optional. Missing fields use default values. */
    type paramsConstructor = type2
    type block = Block.t
    type transaction = Transaction.t

    type event = {
      /** The name of the contract that emitted this event. */
      contractName: string,
      /** The name of the event. */
      eventName: string,
      /** The parameters or arguments associated with this event. */
      params: params,
      /** The unique identifier of the blockchain network where this event occurred. */
      chainId: chainId,
      /** The address of the contract that emitted this event. */
      srcAddress: Address.t,
      /** The index of this event's log within the block. */
      logIndex: int,
      /** The transaction that triggered this event. Configurable in `config.yaml` via the `field_selection` option. */
      transaction: transaction,
      /** The block in which this event was recorded. Configurable in `config.yaml` via the `field_selection` option. */
      block: block,
    }

    type whereParams = {}

    type onEventWhere = Internal.noOnEventWhere
  }

  module U16Log = {

    let name = "U16Log"
    let contractName = contractName
    type params = type24
    /** Event params with all fields optional. Missing fields use default values. */
    type paramsConstructor = type24
    type block = Block.t
    type transaction = Transaction.t

    type event = {
      /** The name of the contract that emitted this event. */
      contractName: string,
      /** The name of the event. */
      eventName: string,
      /** The parameters or arguments associated with this event. */
      params: params,
      /** The unique identifier of the blockchain network where this event occurred. */
      chainId: chainId,
      /** The address of the contract that emitted this event. */
      srcAddress: Address.t,
      /** The index of this event's log within the block. */
      logIndex: int,
      /** The transaction that triggered this event. Configurable in `config.yaml` via the `field_selection` option. */
      transaction: transaction,
      /** The block in which this event was recorded. Configurable in `config.yaml` via the `field_selection` option. */
      block: block,
    }

    type whereParams = {}

    type onEventWhere = Internal.noOnEventWhere
  }

  module TupleLog = {

    let name = "TupleLog"
    let contractName = contractName
    type params = type0
    /** Event params with all fields optional. Missing fields use default values. */
    type paramsConstructor = type0
    type block = Block.t
    type transaction = Transaction.t

    type event = {
      /** The name of the contract that emitted this event. */
      contractName: string,
      /** The name of the event. */
      eventName: string,
      /** The parameters or arguments associated with this event. */
      params: params,
      /** The unique identifier of the blockchain network where this event occurred. */
      chainId: chainId,
      /** The address of the contract that emitted this event. */
      srcAddress: Address.t,
      /** The index of this event's log within the block. */
      logIndex: int,
      /** The transaction that triggered this event. Configurable in `config.yaml` via the `field_selection` option. */
      transaction: transaction,
      /** The block in which this event was recorded. Configurable in `config.yaml` via the `field_selection` option. */
      block: block,
    }

    type whereParams = {}

    type onEventWhere = Internal.noOnEventWhere
  }

  module SimpleStruct = {

    let name = "SimpleStruct"
    let contractName = contractName
    type params = type9
    /** Event params with all fields optional. Missing fields use default values. */
    type paramsConstructor = type9
    type block = Block.t
    type transaction = Transaction.t

    type event = {
      /** The name of the contract that emitted this event. */
      contractName: string,
      /** The name of the event. */
      eventName: string,
      /** The parameters or arguments associated with this event. */
      params: params,
      /** The unique identifier of the blockchain network where this event occurred. */
      chainId: chainId,
      /** The address of the contract that emitted this event. */
      srcAddress: Address.t,
      /** The index of this event's log within the block. */
      logIndex: int,
      /** The transaction that triggered this event. Configurable in `config.yaml` via the `field_selection` option. */
      transaction: transaction,
      /** The block in which this event was recorded. Configurable in `config.yaml` via the `field_selection` option. */
      block: block,
    }

    type whereParams = {}

    type onEventWhere = Internal.noOnEventWhere
  }

  module UnknownLog = {

    let name = "UnknownLog"
    let contractName = contractName
    type params = type25
    /** Event params with all fields optional. Missing fields use default values. */
    type paramsConstructor = type25
    type block = Block.t
    type transaction = Transaction.t

    type event = {
      /** The name of the contract that emitted this event. */
      contractName: string,
      /** The name of the event. */
      eventName: string,
      /** The parameters or arguments associated with this event. */
      params: params,
      /** The unique identifier of the blockchain network where this event occurred. */
      chainId: chainId,
      /** The address of the contract that emitted this event. */
      srcAddress: Address.t,
      /** The index of this event's log within the block. */
      logIndex: int,
      /** The transaction that triggered this event. Configurable in `config.yaml` via the `field_selection` option. */
      transaction: transaction,
      /** The block in which this event was recorded. Configurable in `config.yaml` via the `field_selection` option. */
      block: block,
    }

    type whereParams = {}

    type onEventWhere = Internal.noOnEventWhere
  }

  module BoolLog = {

    let name = "BoolLog"
    let contractName = contractName
    type params = type22
    /** Event params with all fields optional. Missing fields use default values. */
    type paramsConstructor = type22
    type block = Block.t
    type transaction = Transaction.t

    type event = {
      /** The name of the contract that emitted this event. */
      contractName: string,
      /** The name of the event. */
      eventName: string,
      /** The parameters or arguments associated with this event. */
      params: params,
      /** The unique identifier of the blockchain network where this event occurred. */
      chainId: chainId,
      /** The address of the contract that emitted this event. */
      srcAddress: Address.t,
      /** The index of this event's log within the block. */
      logIndex: int,
      /** The transaction that triggered this event. Configurable in `config.yaml` via the `field_selection` option. */
      transaction: transaction,
      /** The block in which this event was recorded. Configurable in `config.yaml` via the `field_selection` option. */
      block: block,
    }

    type whereParams = {}

    type onEventWhere = Internal.noOnEventWhere
  }

  module StrLog = {

    let name = "StrLog"
    let contractName = contractName
    type params = type23
    /** Event params with all fields optional. Missing fields use default values. */
    type paramsConstructor = type23
    type block = Block.t
    type transaction = Transaction.t

    type event = {
      /** The name of the contract that emitted this event. */
      contractName: string,
      /** The name of the event. */
      eventName: string,
      /** The parameters or arguments associated with this event. */
      params: params,
      /** The unique identifier of the blockchain network where this event occurred. */
      chainId: chainId,
      /** The address of the contract that emitted this event. */
      srcAddress: Address.t,
      /** The index of this event's log within the block. */
      logIndex: int,
      /** The transaction that triggered this event. Configurable in `config.yaml` via the `field_selection` option. */
      transaction: transaction,
      /** The block in which this event was recorded. Configurable in `config.yaml` via the `field_selection` option. */
      block: block,
    }

    type whereParams = {}

    type onEventWhere = Internal.noOnEventWhere
  }

  module StringLog = {

    let name = "StringLog"
    let contractName = contractName
    type params = type17
    /** Event params with all fields optional. Missing fields use default values. */
    type paramsConstructor = type17
    type block = Block.t
    type transaction = Transaction.t

    type event = {
      /** The name of the contract that emitted this event. */
      contractName: string,
      /** The name of the event. */
      eventName: string,
      /** The parameters or arguments associated with this event. */
      params: params,
      /** The unique identifier of the blockchain network where this event occurred. */
      chainId: chainId,
      /** The address of the contract that emitted this event. */
      srcAddress: Address.t,
      /** The index of this event's log within the block. */
      logIndex: int,
      /** The transaction that triggered this event. Configurable in `config.yaml` via the `field_selection` option. */
      transaction: transaction,
      /** The block in which this event was recorded. Configurable in `config.yaml` via the `field_selection` option. */
      block: block,
    }

    type whereParams = {}

    type onEventWhere = Internal.noOnEventWhere
  }

  module Option2 = {

    let name = "Option2"
    let contractName = contractName
    type params = type4<type4<type26>>
    /** Event params with all fields optional. Missing fields use default values. */
    type paramsConstructor = type4<type4<type26>>
    type block = Block.t
    type transaction = Transaction.t

    type event = {
      /** The name of the contract that emitted this event. */
      contractName: string,
      /** The name of the event. */
      eventName: string,
      /** The parameters or arguments associated with this event. */
      params: params,
      /** The unique identifier of the blockchain network where this event occurred. */
      chainId: chainId,
      /** The address of the contract that emitted this event. */
      srcAddress: Address.t,
      /** The index of this event's log within the block. */
      logIndex: int,
      /** The transaction that triggered this event. Configurable in `config.yaml` via the `field_selection` option. */
      transaction: transaction,
      /** The block in which this event was recorded. Configurable in `config.yaml` via the `field_selection` option. */
      block: block,
    }

    type whereParams = {}

    type onEventWhere = Internal.noOnEventWhere
  }

  module VecLog = {

    let name = "VecLog"
    let contractName = contractName
    type params = type19<type27>
    /** Event params with all fields optional. Missing fields use default values. */
    type paramsConstructor = type19<type27>
    type block = Block.t
    type transaction = Transaction.t

    type event = {
      /** The name of the contract that emitted this event. */
      contractName: string,
      /** The name of the event. */
      eventName: string,
      /** The parameters or arguments associated with this event. */
      params: params,
      /** The unique identifier of the blockchain network where this event occurred. */
      chainId: chainId,
      /** The address of the contract that emitted this event. */
      srcAddress: Address.t,
      /** The index of this event's log within the block. */
      logIndex: int,
      /** The transaction that triggered this event. Configurable in `config.yaml` via the `field_selection` option. */
      transaction: transaction,
      /** The block in which this event was recorded. Configurable in `config.yaml` via the `field_selection` option. */
      block: block,
    }

    type whereParams = {}

    type onEventWhere = Internal.noOnEventWhere
  }

  module TagsEvent = {

    let name = "TagsEvent"
    let contractName = contractName
    type params = type12
    /** Event params with all fields optional. Missing fields use default values. */
    type paramsConstructor = type12
    type block = Block.t
    type transaction = Transaction.t

    type event = {
      /** The name of the contract that emitted this event. */
      contractName: string,
      /** The name of the event. */
      eventName: string,
      /** The parameters or arguments associated with this event. */
      params: params,
      /** The unique identifier of the blockchain network where this event occurred. */
      chainId: chainId,
      /** The address of the contract that emitted this event. */
      srcAddress: Address.t,
      /** The index of this event's log within the block. */
      logIndex: int,
      /** The transaction that triggered this event. Configurable in `config.yaml` via the `field_selection` option. */
      transaction: transaction,
      /** The block in which this event was recorded. Configurable in `config.yaml` via the `field_selection` option. */
      block: block,
    }

    type whereParams = {}

    type onEventWhere = Internal.noOnEventWhere
  }

  module BytesLog = {

    let name = "BytesLog"
    let contractName = contractName
    type params = type14
    /** Event params with all fields optional. Missing fields use default values. */
    type paramsConstructor = type14
    type block = Block.t
    type transaction = Transaction.t

    type event = {
      /** The name of the contract that emitted this event. */
      contractName: string,
      /** The name of the event. */
      eventName: string,
      /** The parameters or arguments associated with this event. */
      params: params,
      /** The unique identifier of the blockchain network where this event occurred. */
      chainId: chainId,
      /** The address of the contract that emitted this event. */
      srcAddress: Address.t,
      /** The index of this event's log within the block. */
      logIndex: int,
      /** The transaction that triggered this event. Configurable in `config.yaml` via the `field_selection` option. */
      transaction: transaction,
      /** The block in which this event was recorded. Configurable in `config.yaml` via the `field_selection` option. */
      block: block,
    }

    type whereParams = {}

    type onEventWhere = Internal.noOnEventWhere
  }

  module Mint = {

    let name = "Mint"
    let contractName = contractName
    type params = Internal.fuelSupplyParams
    /** Event params with all fields optional. Missing fields use default values. */
    type paramsConstructor = Internal.fuelSupplyParams
    type block = Block.t
    type transaction = Transaction.t

    type event = {
      /** The name of the contract that emitted this event. */
      contractName: string,
      /** The name of the event. */
      eventName: string,
      /** The parameters or arguments associated with this event. */
      params: params,
      /** The unique identifier of the blockchain network where this event occurred. */
      chainId: chainId,
      /** The address of the contract that emitted this event. */
      srcAddress: Address.t,
      /** The index of this event's log within the block. */
      logIndex: int,
      /** The transaction that triggered this event. Configurable in `config.yaml` via the `field_selection` option. */
      transaction: transaction,
      /** The block in which this event was recorded. Configurable in `config.yaml` via the `field_selection` option. */
      block: block,
    }

    type whereParams = {}

    type onEventWhere = Internal.noOnEventWhere
  }

  module Burn = {

    let name = "Burn"
    let contractName = contractName
    type params = Internal.fuelSupplyParams
    /** Event params with all fields optional. Missing fields use default values. */
    type paramsConstructor = Internal.fuelSupplyParams
    type block = Block.t
    type transaction = Transaction.t

    type event = {
      /** The name of the contract that emitted this event. */
      contractName: string,
      /** The name of the event. */
      eventName: string,
      /** The parameters or arguments associated with this event. */
      params: params,
      /** The unique identifier of the blockchain network where this event occurred. */
      chainId: chainId,
      /** The address of the contract that emitted this event. */
      srcAddress: Address.t,
      /** The index of this event's log within the block. */
      logIndex: int,
      /** The transaction that triggered this event. Configurable in `config.yaml` via the `field_selection` option. */
      transaction: transaction,
      /** The block in which this event was recorded. Configurable in `config.yaml` via the `field_selection` option. */
      block: block,
    }

    type whereParams = {}

    type onEventWhere = Internal.noOnEventWhere
  }

  module Transfer = {

    let name = "Transfer"
    let contractName = contractName
    type params = Internal.fuelTransferParams
    /** Event params with all fields optional. Missing fields use default values. */
    type paramsConstructor = Internal.fuelTransferParams
    type block = Block.t
    type transaction = Transaction.t

    type event = {
      /** The name of the contract that emitted this event. */
      contractName: string,
      /** The name of the event. */
      eventName: string,
      /** The parameters or arguments associated with this event. */
      params: params,
      /** The unique identifier of the blockchain network where this event occurred. */
      chainId: chainId,
      /** The address of the contract that emitted this event. */
      srcAddress: Address.t,
      /** The index of this event's log within the block. */
      logIndex: int,
      /** The transaction that triggered this event. Configurable in `config.yaml` via the `field_selection` option. */
      transaction: transaction,
      /** The block in which this event was recorded. Configurable in `config.yaml` via the `field_selection` option. */
      block: block,
    }

    type whereParams = {}

    type onEventWhere = Internal.noOnEventWhere
  }

  type rec eventIdentity<'event, 'paramsConstructor, 'where> =
    | @as("UnitLog") UnitLog: eventIdentity<UnitLog.event, UnitLog.paramsConstructor, UnitLog.onEventWhere>
    | @as("Option_") Option_: eventIdentity<Option_.event, Option_.paramsConstructor, Option_.onEventWhere>
    | @as("SimpleStructWithOptionalField") SimpleStructWithOptionalField: eventIdentity<SimpleStructWithOptionalField.event, SimpleStructWithOptionalField.paramsConstructor, SimpleStructWithOptionalField.onEventWhere>
    | @as("U8Log") U8Log: eventIdentity<U8Log.event, U8Log.paramsConstructor, U8Log.onEventWhere>
    | @as("ArrayLog") ArrayLog: eventIdentity<ArrayLog.event, ArrayLog.paramsConstructor, ArrayLog.onEventWhere>
    | @as("Result") Result: eventIdentity<Result.event, Result.paramsConstructor, Result.onEventWhere>
    | @as("U64Log") U64Log: eventIdentity<U64Log.event, U64Log.paramsConstructor, U64Log.onEventWhere>
    | @as("B256Log") B256Log: eventIdentity<B256Log.event, B256Log.paramsConstructor, B256Log.onEventWhere>
    | @as("U32Log") U32Log: eventIdentity<U32Log.event, U32Log.paramsConstructor, U32Log.onEventWhere>
    | @as("Status") Status: eventIdentity<Status.event, Status.paramsConstructor, Status.onEventWhere>
    | @as("U16Log") U16Log: eventIdentity<U16Log.event, U16Log.paramsConstructor, U16Log.onEventWhere>
    | @as("TupleLog") TupleLog: eventIdentity<TupleLog.event, TupleLog.paramsConstructor, TupleLog.onEventWhere>
    | @as("SimpleStruct") SimpleStruct: eventIdentity<SimpleStruct.event, SimpleStruct.paramsConstructor, SimpleStruct.onEventWhere>
    | @as("UnknownLog") UnknownLog: eventIdentity<UnknownLog.event, UnknownLog.paramsConstructor, UnknownLog.onEventWhere>
    | @as("BoolLog") BoolLog: eventIdentity<BoolLog.event, BoolLog.paramsConstructor, BoolLog.onEventWhere>
    | @as("StrLog") StrLog: eventIdentity<StrLog.event, StrLog.paramsConstructor, StrLog.onEventWhere>
    | @as("StringLog") StringLog: eventIdentity<StringLog.event, StringLog.paramsConstructor, StringLog.onEventWhere>
    | @as("Option2") Option2: eventIdentity<Option2.event, Option2.paramsConstructor, Option2.onEventWhere>
    | @as("VecLog") VecLog: eventIdentity<VecLog.event, VecLog.paramsConstructor, VecLog.onEventWhere>
    | @as("TagsEvent") TagsEvent: eventIdentity<TagsEvent.event, TagsEvent.paramsConstructor, TagsEvent.onEventWhere>
    | @as("BytesLog") BytesLog: eventIdentity<BytesLog.event, BytesLog.paramsConstructor, BytesLog.onEventWhere>
    | @as("Mint") Mint: eventIdentity<Mint.event, Mint.paramsConstructor, Mint.onEventWhere>
    | @as("Burn") Burn: eventIdentity<Burn.event, Burn.paramsConstructor, Burn.onEventWhere>
    | @as("Transfer") Transfer: eventIdentity<Transfer.event, Transfer.paramsConstructor, Transfer.onEventWhere>
}

module Greeter = {
let abi = FuelSDK.transpileAbi((await Utils.importPathWithJson(`../abis/greeter-abi.json`))["default"])
/*Silence warning of label defined in multiple types*/
@@warning("-30")
type rec type0 = string
 @tag("case") and type1 = | InvalidContractSender({payload: type8}) | ToThrow({payload: type8})
 @tag("case") and type2<'t> = | None({payload: type8}) | Some({payload: 't})
 and type4 = {user: type7}
 and type5 = {value: type9}
 and type6 = {user: type7, greeting: type5}
 and type7 = {bits: type0}
 and type8 = unit
 and type9 = string
@@warning("+30")
let contractName = "Greeter"

  module NewGreeting = {

    let name = "NewGreeting"
    let contractName = contractName
    type params = type6
    /** Event params with all fields optional. Missing fields use default values. */
    type paramsConstructor = type6
    type block = Block.t
    type transaction = Transaction.t

    type event = {
      /** The name of the contract that emitted this event. */
      contractName: string,
      /** The name of the event. */
      eventName: string,
      /** The parameters or arguments associated with this event. */
      params: params,
      /** The unique identifier of the blockchain network where this event occurred. */
      chainId: chainId,
      /** The address of the contract that emitted this event. */
      srcAddress: Address.t,
      /** The index of this event's log within the block. */
      logIndex: int,
      /** The transaction that triggered this event. Configurable in `config.yaml` via the `field_selection` option. */
      transaction: transaction,
      /** The block in which this event was recorded. Configurable in `config.yaml` via the `field_selection` option. */
      block: block,
    }

    type whereParams = {}

    type onEventWhere = Internal.noOnEventWhere
  }

  module ClearGreeting = {

    let name = "ClearGreeting"
    let contractName = contractName
    type params = type4
    /** Event params with all fields optional. Missing fields use default values. */
    type paramsConstructor = type4
    type block = Block.t
    type transaction = Transaction.t

    type event = {
      /** The name of the contract that emitted this event. */
      contractName: string,
      /** The name of the event. */
      eventName: string,
      /** The parameters or arguments associated with this event. */
      params: params,
      /** The unique identifier of the blockchain network where this event occurred. */
      chainId: chainId,
      /** The address of the contract that emitted this event. */
      srcAddress: Address.t,
      /** The index of this event's log within the block. */
      logIndex: int,
      /** The transaction that triggered this event. Configurable in `config.yaml` via the `field_selection` option. */
      transaction: transaction,
      /** The block in which this event was recorded. Configurable in `config.yaml` via the `field_selection` option. */
      block: block,
    }

    type whereParams = {}

    type onEventWhere = Internal.noOnEventWhere
  }

  type rec eventIdentity<'event, 'paramsConstructor, 'where> =
    | @as("NewGreeting") NewGreeting: eventIdentity<NewGreeting.event, NewGreeting.paramsConstructor, NewGreeting.onEventWhere>
    | @as("ClearGreeting") ClearGreeting: eventIdentity<ClearGreeting.event, ClearGreeting.paramsConstructor, ClearGreeting.onEventWhere>
}

/** Contract configuration with name and ABI. */
type indexerContract = {
  /** The contract name. */
  name: string,
  /** The contract ABI. */
  abi: unknown,
  /** The contract addresses. */
  addresses: array<Address.t>,
}

/** Per-chain configuration for the indexer. */
type indexerChain = {
  /** The chain ID. */
  id: chainId,
  /** The chain name. */
  name: string,
  /** The block number to start indexing from. */
  startBlock: int,
  /** The block number to stop indexing at (if specified). */
  endBlock: option<int>,
  /** Whether the chain has completed initial sync and is processing live events. */
  isLive: bool,
  \"AllEvents": indexerContract,
  \"Greeter": indexerContract,
}

/** Strongly-typed record of chain configurations keyed by chain ID. */
type indexerChains = {
  \"0": indexerChain,
}

@tag("contract")
type eventIdentity<'event, 'paramsConstructor, 'where> =
  | AllEvents(AllEvents.eventIdentity<'event, 'paramsConstructor, 'where>)
  | Greeter(Greeter.eventIdentity<'event, 'paramsConstructor, 'where>)

@tag("kind")
type simulateItemConstructor<'event, 'paramsConstructor, 'where> =
  | OnEvent({
      event: eventIdentity<'event, 'paramsConstructor, 'where>,
      params: 'paramsConstructor,
      block?: Envio.fuelBlockInput,
      transaction?: Envio.fuelTransactionInput,
    })

let makeSimulateItem = (
  constructor: simulateItemConstructor<'event, 'paramsConstructor, 'where>,
): Envio.fuelSimulateItem => {
  event: (constructor->Utils.magic)["event"]["_0"],
  contract: (constructor->Utils.magic)["event"]["contract"],
  params: (constructor->Utils.magic)["params"],
  block: (constructor->Utils.magic)["block"],
  transaction: (constructor->Utils.magic)["transaction"],
}

/** Metadata and configuration for the indexer. */
type indexer = {
  /** The name of the indexer from config.yaml. */
  name: string,
  /** The description of the indexer from config.yaml. */
  description: option<string>,
  /** Array of all chain IDs this indexer operates on. */
  chainIds: array<chainId>,
  /** Per-chain configuration keyed by chain ID. */
  chains: indexerChains,
  /** Register an event handler. */
  onEvent: 'event 'paramsConstructor 'where. (
    onEventOptions<eventIdentity<'event, 'paramsConstructor, 'where>, 'where>,
    Internal.genericHandler<Internal.genericHandlerArgs<'event, handlerContext>>,
  ) => unit,
  /** Register a contract register handler for dynamic contract indexing. */
  contractRegister: 'event 'paramsConstructor 'where. (
    onEventOptions<eventIdentity<'event, 'paramsConstructor, 'where>, 'where>,
    Internal.genericContractRegister<Internal.genericContractRegisterArgs<'event, contractRegisterContext>>,
  ) => unit,
  /** Register a Block Handler. Evaluates `where` once per configured chain at registration time. */
  onBlock: (
    Envio.onBlockOptions<indexerChain>,
    Envio.fuelOnBlockArgs<handlerContext> => promise<unit>,
  ) => unit,
}

/** Get chain configuration by chain ID with exhaustive pattern matching. */
let getChainById = (indexer: indexer, chainId: chainId): indexerChain => {
switch chainId {
  | #0 => indexer.chains.\"0"
}
}

type testIndexerProcessConfigChains = {
  \"0"?: TestIndexer.fuelChainConfig,
}

type testIndexerProcessConfig = {
  chains: testIndexerProcessConfigChains,
}

/** Entity operations for direct access outside handlers. */
type testIndexerEntityOperations<'entity> = {
  /** Get an entity by ID. */
  get: string => promise<option<'entity>>,
  /** Get all entities. */
  getAll: unit => promise<array<'entity>>,
  /** Get an entity by ID or throw if not found. */
  getOrThrow: (string, ~message: string=?) => promise<'entity>,
  /** Set (create or update) an entity. */
  set: 'entity => unit,
}

/** Test indexer type with process method, entity access, and chain info. */
type testIndexer = {
  /** Process blocks for the specified chains and return progress with changes. */
  process: testIndexerProcessConfig => promise<TestIndexer.processResult>,
  /** Array of all chain IDs this indexer operates on. */
  chainIds: array<chainId>,
  /** Per-chain configuration keyed by chain ID. */
  chains: indexerChains,
  \"User": testIndexerEntityOperations<Entities.User.t>,
}

@get_index external getTestIndexerEntityOperations: (testIndexer, Entities.name<'entity>) => testIndexerEntityOperations<'entity> = ""

@module("envio") external indexer: indexer = "indexer"

@module("envio") external createTestIndexer: unit => testIndexer = "createTestIndexer"
