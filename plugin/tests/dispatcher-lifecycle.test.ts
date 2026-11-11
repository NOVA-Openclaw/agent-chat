/**
 * Unit tests for SE#1475 / WP#862: reply-dispatcher reservation lifecycle.
 *
 * The plugin must release the dispatcher reservation (markComplete) after
 * every turn. A fake runtime counts pending reservations exactly like the
 * core registry: each createReplyDispatcherWithTyping() increments pending to
 * 1, and only markComplete() decrements it.
 */

import { describe, it, beforeEach } from "node:test";
import assert from "node:assert/strict";
import type { OpenClawConfig, PluginRuntime } from "openclaw/plugin-sdk";
import { processAgentChatMessage } from "../src/channel.js";
import { deliverDigest } from "../src/digest.js";
import { setAgentChatRuntime } from "../src/runtime.js";

const SAMPLE_MESSAGE = {
  id: 42,
  sender: "nova",
  message: "hello world",
  recipients: ["newhart"],
  reply_to: null,
  timestamp: new Date("2026-10-02T19:00:00Z"),
};

function makeFakeClient() {
  const queries: Array<{ sql: string; params: unknown[] }> = [];
  return {
    queries,
    query(sql: string, params?: unknown[]) {
      queries.push({ sql, params: params ?? [] });
      const trimmedLower = sql.trim().toLowerCase();
      if (
        trimmedLower.startsWith("insert into public.agent_chat_processed") &&
        trimmedLower.includes("returning")
      ) {
        return Promise.resolve({
          rows: [{ chat_id: params?.[0], agent: params?.[1], status: "received" }],
        });
      }
      if (trimmedLower.startsWith("update agent_chat_processed")) {
        return Promise.resolve({ rows: [] });
      }
      if (trimmedLower.startsWith("insert into agent_chat_processed")) {
        return Promise.resolve({ rows: [] });
      }
      if (trimmedLower.startsWith("select agent_chat_is_muted")) {
        return Promise.resolve({ rows: [{ muted: false }] });
      }
      return Promise.resolve({ rows: [] });
    },
  };
}

function makeFakeCtx(): {
  log: {
    info: (m: string) => void;
    error: (m: string) => void;
    debug: (m: string) => void;
  };
  account: { config: { pollIntervalMs: number } };
  cfg: OpenClawConfig;
} {
  return {
    log: { info: () => {}, error: () => {}, debug: () => {} },
    account: { config: { pollIntervalMs: 1000 } },
    cfg: {} as OpenClawConfig,
  };
}

interface FakeRuntimeResult {
  runtime: PluginRuntime;
  /** Number of unreleased dispatcher reservations. */
  pending: number;
  /** Metadata captured for each created dispatcher. */
  reservations: Array<{ sessionKey?: unknown; runId?: unknown }>;
  /** Number of times dispatchReplyFromConfig was invoked. */
  dispatchCalls: number;
  /** True if the new withReplyDispatcher helper was used. */
  usedWithReplyDispatcher: boolean;
}

function makeFakeRuntime(options: {
  withReplyDispatcher?: boolean;
  acceptMetadata?: boolean;
  dispatchThrows?: boolean;
} = {}): FakeRuntimeResult {
  const { withReplyDispatcher: hasWithReplyDispatcher, acceptMetadata, dispatchThrows } = options;
  let pending = 0;
  const reservations: Array<{ sessionKey?: unknown; runId?: unknown }> = [];
  let dispatchCalls = 0;
  let usedWithReplyDispatcher = false;

  function createDispatcher(opts: Record<string, unknown>) {
    if (opts.metadata && !acceptMetadata) {
      throw new Error("metadata not supported");
    }
    pending++;
    const meta = (opts.metadata ?? {}) as { sessionKey?: unknown; runId?: unknown };
    reservations.push({ sessionKey: meta.sessionKey, runId: meta.runId });

    const dispatcher = {
      waitForIdle: async () => {},
      markComplete: () => {
        if (pending > 0) pending--;
      },
    };

    return {
      dispatcher,
      replyOptions: {},
      markDispatchIdle: () => {},
    };
  }

  const result: FakeRuntimeResult = {
    runtime: {
      channel: {
        reply: {
          resolveEnvelopeFormatOptions: () => ({}),
          formatInboundEnvelope(input: { from: string; body: string }) {
            return `${input.from}: ${input.body}`;
          },
          formatAgentEnvelope(input: { body: string }) {
            return input.body;
          },
          finalizeInboundContext(ctx: Record<string, unknown>) {
            return ctx;
          },
          createReplyDispatcherWithTyping: (opts: Record<string, unknown>) =>
            createDispatcher(opts),
          dispatchReplyFromConfig: async () => {
            dispatchCalls++;
            if (options.dispatchThrows) {
              throw new Error("dispatch exploded");
            }
          },
          ...(hasWithReplyDispatcher
            ? {
                withReplyDispatcher: async (args: {
                  dispatcher: unknown;
                  run: () => Promise<unknown>;
                }) => {
                  usedWithReplyDispatcher = true;
                  try {
                    return await args.run();
                  } finally {
                    // withReplyDispatcher is defined to settle the dispatcher,
                    // which means markComplete then waitForIdle.
                    if (pending > 0) pending--;
                  }
                },
              }
            : {}),
        },
      },
    } as unknown as PluginRuntime,
    get pending() {
      return pending;
    },
    get reservations() {
      return reservations;
    },
    get dispatchCalls() {
      return dispatchCalls;
    },
    get usedWithReplyDispatcher() {
      return usedWithReplyDispatcher;
    },
  };

  return result;
}

function fakeClientToPg(client: ReturnType<typeof makeFakeClient>): import("pg").Client {
  return client as unknown as import("pg").Client;
}

function fakeCtxToGateway(
  ctx: ReturnType<typeof makeFakeCtx>,
): Parameters<typeof processAgentChatMessage>[0]["ctx"] {
  return ctx as unknown as Parameters<typeof processAgentChatMessage>[0]["ctx"];
}

describe("WP#862: processAgentChatMessage releases dispatcher reservations", () => {
  beforeEach(() => {
    // Ensure a clean global runtime for each test.
    setAgentChatRuntime({ channel: {} } as unknown as PluginRuntime);
  });

  it("success path leaves 0 pending on OLD runtime (markComplete finally)", async () => {
    const fake = makeFakeRuntime({ withReplyDispatcher: false, acceptMetadata: false });
    setAgentChatRuntime(fake.runtime);

    const client = makeFakeClient();
    const ctx = makeFakeCtx();
    await processAgentChatMessage({
      message: SAMPLE_MESSAGE,
      client: fakeClientToPg(client),
      dbUser: "newhart",
      gatewayAgentId: "newhart",
      cfg: ctx.cfg,
      ctx: fakeCtxToGateway(ctx),
    });

    assert.strictEqual(fake.pending, 0, "dispatcher reservation must be released");
    assert.strictEqual(fake.dispatchCalls, 1);
  });

  it("success path leaves 0 pending on NEW runtime (withReplyDispatcher)", async () => {
    const fake = makeFakeRuntime({ withReplyDispatcher: true, acceptMetadata: true });
    setAgentChatRuntime(fake.runtime);

    const client = makeFakeClient();
    const ctx = makeFakeCtx();
    await processAgentChatMessage({
      message: SAMPLE_MESSAGE,
      client: fakeClientToPg(client),
      dbUser: "newhart",
      gatewayAgentId: "newhart",
      cfg: ctx.cfg,
      ctx: fakeCtxToGateway(ctx),
    });

    assert.strictEqual(fake.pending, 0, "dispatcher reservation must be released");
    assert.strictEqual(fake.dispatchCalls, 1);
    assert.strictEqual(fake.usedWithReplyDispatcher, true);
  });

  it("dispatch error-before-reply leaves 0 pending on OLD runtime", async () => {
    const fake = makeFakeRuntime({ withReplyDispatcher: false, dispatchThrows: true });
    setAgentChatRuntime(fake.runtime);

    const client = makeFakeClient();
    const ctx = makeFakeCtx();
    await processAgentChatMessage({
      message: SAMPLE_MESSAGE,
      client: fakeClientToPg(client),
      dbUser: "newhart",
      gatewayAgentId: "newhart",
      cfg: ctx.cfg,
      ctx: fakeCtxToGateway(ctx),
    });

    assert.strictEqual(fake.pending, 0, "dispatcher reservation must be released on error");
    assert.strictEqual(fake.dispatchCalls, 1);
    const failedUpdate = client.queries.find(
      (q) =>
        q.sql.trim().toLowerCase().startsWith("update agent_chat_processed") &&
        q.sql.toLowerCase().includes("set status = 'failed'") &&
        q.params[0] === SAMPLE_MESSAGE.id,
    );
    assert.ok(failedUpdate, "message should be marked failed");
  });

  it("dispatch error-before-reply leaves 0 pending on NEW runtime", async () => {
    const fake = makeFakeRuntime({ withReplyDispatcher: true, dispatchThrows: true });
    setAgentChatRuntime(fake.runtime);

    const client = makeFakeClient();
    const ctx = makeFakeCtx();
    await processAgentChatMessage({
      message: SAMPLE_MESSAGE,
      client: fakeClientToPg(client),
      dbUser: "newhart",
      gatewayAgentId: "newhart",
      cfg: ctx.cfg,
      ctx: fakeCtxToGateway(ctx),
    });

    assert.strictEqual(fake.pending, 0, "dispatcher reservation must be released on error");
    assert.strictEqual(fake.usedWithReplyDispatcher, true);
  });

  it("passes metadata when the runtime accepts it", async () => {
    const fake = makeFakeRuntime({ withReplyDispatcher: true, acceptMetadata: true });
    setAgentChatRuntime(fake.runtime);

    const client = makeFakeClient();
    const ctx = makeFakeCtx();
    await processAgentChatMessage({
      message: SAMPLE_MESSAGE,
      client: fakeClientToPg(client),
      dbUser: "newhart",
      gatewayAgentId: "newhart",
      cfg: ctx.cfg,
      ctx: fakeCtxToGateway(ctx),
    });

    assert.strictEqual(fake.reservations.length, 1);
    assert.match(String(fake.reservations[0].sessionKey), /agent:newhart:agent_chat:nova/);
  });

  it("falls back to no metadata on OLD runtimes that reject it", async () => {
    const fake = makeFakeRuntime({ withReplyDispatcher: false, acceptMetadata: false });
    setAgentChatRuntime(fake.runtime);

    const client = makeFakeClient();
    const ctx = makeFakeCtx();
    await processAgentChatMessage({
      message: SAMPLE_MESSAGE,
      client: fakeClientToPg(client),
      dbUser: "newhart",
      gatewayAgentId: "newhart",
      cfg: ctx.cfg,
      ctx: fakeCtxToGateway(ctx),
    });

    assert.strictEqual(fake.pending, 0);
    assert.strictEqual(fake.reservations.length, 1);
    assert.strictEqual(fake.reservations[0].sessionKey, undefined);
  });
});

describe("WP#862: deliverDigest releases dispatcher reservations", () => {
  beforeEach(() => {
    setAgentChatRuntime({ channel: {} } as unknown as PluginRuntime);
  });

  it("success path leaves 0 pending on OLD runtime", async () => {
    const fake = makeFakeRuntime({ withReplyDispatcher: false, acceptMetadata: false });
    setAgentChatRuntime(fake.runtime);

    await deliverDigest({
      runtime: fake.runtime,
      cfg: {} as OpenClawConfig,
      agentName: "newhart",
      digestText: "digest body",
    });

    assert.strictEqual(fake.pending, 0, "digest dispatcher reservation must be released");
    assert.strictEqual(fake.dispatchCalls, 1);
  });

  it("success path leaves 0 pending on NEW runtime", async () => {
    const fake = makeFakeRuntime({ withReplyDispatcher: true, acceptMetadata: true });
    setAgentChatRuntime(fake.runtime);

    await deliverDigest({
      runtime: fake.runtime,
      cfg: {} as OpenClawConfig,
      agentName: "newhart",
      digestText: "digest body",
    });

    assert.strictEqual(fake.pending, 0, "digest dispatcher reservation must be released");
    assert.strictEqual(fake.usedWithReplyDispatcher, true);
  });

  it("dispatch error leaves 0 pending on OLD runtime", async () => {
    const fake = makeFakeRuntime({ withReplyDispatcher: false, dispatchThrows: true });
    setAgentChatRuntime(fake.runtime);

    await deliverDigest({
      runtime: fake.runtime,
      cfg: {} as OpenClawConfig,
      agentName: "newhart",
      digestText: "digest body",
    });

    assert.strictEqual(fake.pending, 0, "digest dispatcher reservation must be released on error");
  });

  it("passes metadata when the runtime accepts it", async () => {
    const fake = makeFakeRuntime({ withReplyDispatcher: true, acceptMetadata: true });
    setAgentChatRuntime(fake.runtime);

    await deliverDigest({
      runtime: fake.runtime,
      cfg: {} as OpenClawConfig,
      agentName: "newhart",
      digestText: "digest body",
    });

    assert.strictEqual(fake.reservations.length, 1);
    assert.match(String(fake.reservations[0].sessionKey), /agent:newhart:agent_chat/);
  });
});
