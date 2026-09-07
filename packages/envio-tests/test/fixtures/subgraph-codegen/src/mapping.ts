import { LogSetMarginRatio, Margin } from "../generated/Margin/Margin";
import { Probe } from "../generated/schema";

export function handleLogSetMarginRatio(event: LogSetMarginRatio): void {
  let ratio = Margin.bind(event.address).getMarginRatio();
  let probe = new Probe("ratio");
  probe.name = ratio.value.toString();
  probe.save();
}
