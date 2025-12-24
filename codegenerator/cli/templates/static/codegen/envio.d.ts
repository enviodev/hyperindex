import type config from "./internal.config.ts";

declare module "envio" {
  interface Global {
    config: typeof config;
  }
}

export {};
