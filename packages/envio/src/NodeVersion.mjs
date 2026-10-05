const MINIMUM = [22, 15, 0];

// The message for a Node.js older than envio supports, or undefined.
export const unsupportedNodeMessage = () => {
  const current = process.versions.node;
  const parts = current.split(".").map(Number);
  const index = MINIMUM.findIndex((minimum, i) => parts[i] !== minimum);
  if (index === -1 || parts[index] > MINIMUM[index]) return undefined;
  return [
    `envio needs Node.js ${MINIMUM.join(".")} or newer, and this is Node.js ${current}.`,
    "Install a newer one from https://nodejs.org/en/download, or with your version manager, for example: nvm install --lts",
  ].join("\n");
};
