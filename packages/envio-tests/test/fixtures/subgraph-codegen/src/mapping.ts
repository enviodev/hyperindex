import { LogSetMarginRatio, Margin } from "../generated/Margin/Margin";
import { ERC20 } from "../generated/Margin/ERC20";
import { Probe } from "../generated/schema";

export function handleLogSetMarginRatio(event: LogSetMarginRatio): void {
  let ratio = Margin.bind(event.address).getMarginRatio();
  let probe = new Probe("ratio");
  probe.name = ratio.value.toString();
  probe.save();

  let decimals = ERC20.bind(event.address).try_decimals();
  let token = new Probe("decimals");
  token.name = decimals.reverted ? "reverted" : decimals.value.toString();
  token.save();
}
