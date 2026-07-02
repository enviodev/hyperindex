/**
 * Minimal GraphQL-over-WebSocket clients for both protocols Hasura serves
 * on /v1/graphql:
 * - "graphql-transport-ws" (modern graphql-ws):    connection_init/ack,
 *   subscribe -> next/complete, ping/pong
 * - "graphql-ws" (legacy subscriptions-transport-ws): connection_init/ack,
 *   start -> data/complete, ka keepalives
 *
 * Hand-rolled so the differential suite controls and observes every frame.
 */

import WebSocket from "ws";

export type WsProtocol = "graphql-transport-ws" | "graphql-ws";

export interface WsFrame {
  type: string;
  id?: string;
  payload?: unknown;
}

export interface WsSession {
  send(frame: WsFrame): void;
  /** Waits for the next frame matching the filter (keepalives skipped unless asked for). */
  next(
    filter?: (f: WsFrame) => boolean,
    timeoutMs?: number
  ): Promise<WsFrame>;
  /** All frames received so far (including keepalives). */
  frames: WsFrame[];
  close(): Promise<void>;
}

export async function connect(
  url: string,
  protocol: WsProtocol,
  options: { adminSecret?: string; initTimeoutMs?: number } = {}
): Promise<WsSession> {
  const socket = new WebSocket(url, protocol);
  const frames: WsFrame[] = [];
  const waiters: {
    filter: (f: WsFrame) => boolean;
    resolve: (f: WsFrame) => void;
  }[] = [];
  let closed = false;
  let closeWaiter: (() => void) | undefined;

  socket.on("message", (data) => {
    const frame = JSON.parse(data.toString()) as WsFrame;
    frames.push(frame);
    const i = waiters.findIndex((w) => w.filter(frame));
    if (i >= 0) {
      const [w] = waiters.splice(i, 1);
      w!.resolve(frame);
    }
  });
  socket.on("close", () => {
    closed = true;
    closeWaiter?.();
  });

  await new Promise<void>((resolve, reject) => {
    socket.once("open", () => resolve());
    socket.once("error", reject);
  });

  const session: WsSession = {
    frames,
    send(frame) {
      socket.send(JSON.stringify(frame));
    },
    next(filter = (f) => f.type !== "ka" && f.type !== "ping", timeoutMs = 10_000) {
      const existing = frames.find((f) => !consumed.has(f) && filter(f));
      if (existing) {
        consumed.add(existing);
        return Promise.resolve(existing);
      }
      return new Promise<WsFrame>((resolve, reject) => {
        const timer = setTimeout(
          () =>
            reject(
              new Error(
                `Timed out waiting for ws frame; got so far: ${JSON.stringify(frames)}`
              )
            ),
          timeoutMs
        );
        waiters.push({
          filter,
          resolve: (f) => {
            clearTimeout(timer);
            consumed.add(f);
            resolve(f);
          },
        });
      });
    },
    close() {
      if (closed) return Promise.resolve();
      const done = new Promise<void>((resolve) => {
        closeWaiter = resolve;
      });
      socket.close();
      return done;
    },
  };
  const consumed = new Set<WsFrame>();

  const initPayload = options.adminSecret
    ? { headers: { "x-hasura-admin-secret": options.adminSecret } }
    : {};
  session.send({ type: "connection_init", payload: initPayload });
  await session.next((f) => f.type === "connection_ack", options.initTimeoutMs ?? 10_000);
  return session;
}

/** Subscribe and return the stream of data payloads via an async helper. */
export interface Subscription {
  /** Waits for the next data payload (protocol-normalized). */
  nextData(timeoutMs?: number): Promise<unknown>;
  /** Waits for the completion frame. */
  waitComplete(timeoutMs?: number): Promise<void>;
  /** Waits for a protocol error frame and returns its payload. */
  nextError(timeoutMs?: number): Promise<unknown>;
  stop(): void;
}

let nextId = 1;

export function subscribe(
  session: WsSession,
  protocol: WsProtocol,
  payload: { query: string; variables?: Record<string, unknown> }
): Subscription {
  const id = String(nextId++);
  const startType = protocol === "graphql-transport-ws" ? "subscribe" : "start";
  const dataType = protocol === "graphql-transport-ws" ? "next" : "data";
  const stopType = protocol === "graphql-transport-ws" ? "complete" : "stop";
  session.send({ type: startType, id, payload });

  return {
    async nextData(timeoutMs = 15_000) {
      const frame = await session.next(
        (f) => f.id === id && (f.type === dataType || f.type === "error"),
        timeoutMs
      );
      if (f_isError(frame)) {
        throw new Error(`subscription error: ${JSON.stringify(frame.payload)}`);
      }
      return frame.payload;
    },
    async nextError(timeoutMs = 15_000) {
      const frame = await session.next(
        (f) => f.id === id && f.type === "error",
        timeoutMs
      );
      return frame.payload;
    },
    async waitComplete(timeoutMs = 15_000) {
      await session.next((f) => f.id === id && f.type === "complete", timeoutMs);
    },
    stop() {
      session.send({ type: stopType, id });
    },
  };

  function f_isError(f: WsFrame): boolean {
    return f.type === "error";
  }
}
