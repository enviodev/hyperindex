export type {
  logger as Logger,
  effect as Effect,
  effectContext as EffectContext,
  effectArgs as EffectArgs,
  effectOptions as EffectOptoins,
} from "./src/Envio.gen.ts";
export type { EffectCaller } from "./src/Types.ts";

import type {
  effect as Effect,
  effectOptions as EffectOptoins,
} from "./src/Envio.gen.ts";

export function createEffect<I, O = unknown>(
  options: EffectOptoins<I, O>
): Effect<I, O>;
