(globalThis as { registeredBy?: string }).registeredBy = "side-effect";

export const registered = true;
