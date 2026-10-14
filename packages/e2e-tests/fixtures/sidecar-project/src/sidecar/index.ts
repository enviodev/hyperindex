// Stands in for what `createSidecar(contract, {...})` returns, so the tests
// exercise only the `envio sidecar` / `envio dev` side of the handoff.
type StartOptions = { entities?: { name: string }[] };

const sidecar = {
  async start(options: StartOptions = {}) {
    const keepAlive = setInterval(() => {}, 1_000);
    const entities = (options.entities ?? []).map((entity) => entity.name).join(",");
    const env = [
      process.env.ENVIO_SIDECAR_INTERNAL_URL,
      process.env.ENVIO_INDEXER_INTERNAL_URL,
      process.env.ENVIO_SIDECAR_PORT,
      process.env.ENVIO_GRAPHQL_URL,
    ].join(" ");
    console.log(
      `fake sidecar started entities=${entities} config=${process.env.ENVIO_CONFIG} pid=${process.pid} env=${env}`
    );
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
