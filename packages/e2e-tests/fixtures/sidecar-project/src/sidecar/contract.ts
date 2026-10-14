import { defineSidecar, S } from "envio";

export default defineSidecar({
  functions: {
    greet: { input: { name: S.string } },
  },
});
