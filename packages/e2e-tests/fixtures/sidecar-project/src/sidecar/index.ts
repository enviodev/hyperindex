// Stands in for what `createSidecar(contract, {...})` returns, so the test
// exercises only the `envio sidecar` side of the handoff.
type StartOptions = { entities?: { name: string }[] };

const sidecar = {
  async start(options: StartOptions = {}) {
    const keepAlive = setInterval(() => {}, 1_000);
    const entities = (options.entities ?? []).map((entity) => entity.name).join(",");
    console.log(`fake sidecar started entities=${entities} config=${process.env.ENVIO_CONFIG}`);
    return {
      internalPort: 9901,
      publicPort: 9900,
      close: async () => {
        clearInterval(keepAlive);
        console.log("fake sidecar closed");
      },
    };
  },
};

export default sidecar;
