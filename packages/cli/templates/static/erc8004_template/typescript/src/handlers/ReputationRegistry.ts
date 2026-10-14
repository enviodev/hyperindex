import { indexer, type Feedback } from "envio";

// feedbackURI and feedbackHash live only in this log: they are non-indexed and
// readFeedback() does not return them, so indexing is the only way to reach the
// pointer to an agent's evidence.
indexer.onEvent(
  { contract: "ReputationRegistry", event: "NewFeedback" },
  async ({ event, context }) => {
    const id =
      event.params.agentId.toString() +
      "-" +
      event.params.clientAddress +
      "-" +
      event.params.feedbackIndex.toString();

    const feedback: Feedback = {
      id,
      agent_id: event.params.agentId.toString(),
      clientAddress: event.params.clientAddress,
      value: event.params.value,
      valueDecimals: Number(event.params.valueDecimals),
      feedbackURI: event.params.feedbackURI,
      feedbackHash: event.params.feedbackHash,
    };
    context.Feedback.set(feedback);
  },
);
