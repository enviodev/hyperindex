import { Bytes, ethereum } from "@graphprotocol/graph-ts";
import { Registered } from "../generated/Registry/Registry";
import { Probe } from "../generated/schema";

export function handleRegistered(event: Registered): void {
  // Through the getters graph codegen generated: `members`, and `param1` for
  // the parameter the ABI left unnamed.
  let first = new Probe("members");
  first.name = event.params.members[1].toHexString() + "/" + event.params.param1.toString();
  first.save();

  // Positionally, the way a mapping reads a parameter its ABI didn't name.
  let raw = new Probe("parameters");
  raw.name = event.parameters[0].value.toAddressArray().length.toString();
  raw.save();

  // An \`ethereum.Value\` is tagged with graph-ts' ABI kinds, which a mapping
  // can switch on — not with the store's.
  let decoded = ethereum.decode(
    "(address,uint256)",
    Bytes.fromHexString(
      "0x00000000000000000000000000000000000000000000000000000000000000aa0000000000000000000000000000000000000000000000000000000000000007",
    ),
  )!;
  let kinds = new Probe("kinds");
  kinds.name =
    event.parameters[0].value.kind.toString() +
    "," +
    event.parameters[0].value.toArray()[0].kind.toString() +
    "," +
    event.parameters[1].value.kind.toString() +
    "|" +
    decoded.kind.toString() +
    "," +
    decoded.toTuple()[0].kind.toString() +
    "," +
    decoded.toTuple()[1].toBigInt().toString();
  kinds.save();
}
