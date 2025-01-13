exception ParseError(exn)
exception UnknownContractName({contractName: string})

let parseLogViemOrThrow = (
  contractNameAbiMapping: dict<Ethers.abi>,
  ~contractName,
  ~topics,
  ~data,
) => {
  switch contractNameAbiMapping->Utils.Dict.dangerouslyGetNonOption(contractName) {
  | None => raise(UnknownContractName({contractName: contractName}))
  | Some(abi) =>
    let viemLog: Viem.eventLog = {
      abi,
      data,
      topics,
    }

    try viemLog->Viem.decodeEventLogOrThrow catch {
    | exn => raise(ParseError(exn))
    }
  }
}
