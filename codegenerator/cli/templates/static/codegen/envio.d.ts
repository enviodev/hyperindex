import type config from "./envio.config.ts";

declare module "envio" {
  interface Global {
    config: typeof config;
  }
}

export {};
