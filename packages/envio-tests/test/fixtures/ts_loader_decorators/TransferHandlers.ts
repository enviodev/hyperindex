import { indexer } from "envio";

const logged = (value: () => number, _context: ClassMethodDecoratorContext) => value;

class Counter {
  @logged
  count() {
    return 1;
  }
}

indexer.onEvent({ contract: "Token", event: "Transfer" }, async ({ context }) => {
  context.Transfer.set({ id: String(new Counter().count()) });
});
