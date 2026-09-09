type hex = EvmTypes.Hex.t

let fromAddress: Address.t => hex = addr => addr->(Utils.magic: Address.t => hex)->Viem.pad
