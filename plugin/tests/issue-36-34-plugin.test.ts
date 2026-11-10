/**
 * Plugin-layer unit tests for SE #1453 step 5 chunk 2: agent-chat plugin
 * fixes for issues #36 and #34.
 *
 * Coverage maps to QA groups A, B, E, F, G, H, K, plus mute check and
 * breaker alert injection. Tests use fake PG clients so they never touch
 * the live agent_chat DB.
 */

import { describe, it, before } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import type { PluginRuntime, OpenClawConfig } from "openclaw/plugin-sdk";
import {
  buildSessionLabel,
  buildWakeLine,
  claimMessage,
  injectBreakerAlert,
  insertOutboundMessage,
  processAgentChatMessage,
  sanitizeSessionPeer,
} from "../src/channel.js";
import { deliverDigest } from "../src/digest.js";
import { setAgentChatRuntime } from "../src/runtime.js";
import { createAgentChatTools, MarkParams, MuteParams, SendParams } from "../src/tools.js";
import { Value } from "@sinclair/typebox/value";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const manifestPath = path.join(__dirname, "..", "openclaw.plugin.json");

const SAMPLE_MESSAGE = {
  id: 42,
  sender: "nova",
  message: "hello world",
  recipients: ["newhart"],
  reply_to: null,
  timestamp: new Date("2026-10-02T19:00:00Z"),
};

function makeFakeClient(options: {
  claimReturns?: boolean;
  isMuted?: boolean;
  pendingAlerts?: unknown[];
  markApplied?: bigint[];
  sendReturns?: number | null;
  muteReturns?: Date | null;
  unmuteReturns?: boolean;
} = {}): {
  queries: Array<{ sql: string; params: unknown[] }>;
  connect: () => Promise<void>;
  end: () => Promise<void>;
  query: (sql: string, params?: unknown[]) => Promise<{ rows: unknown[] }>;
  resetClaim: () => void;
} {
  const queries: Array<{ sql: string; params: unknown[] }> = [];
  let claimGiven = options.claimReturns !== false;
  return {
    queries,
    connect: async () => {},
    end: async () => {},
    resetClaim: () => {
      claimGiven = options.claimReturns !== false;
    },
    query(sql: string, params?: unknown[]) {
      queries.push({ sql, params: params ?? [] });
      const trimmedLower = sql.trim().toLowerCase();

      if (
        trimmedLower.startsWith("insert into public.agent_chat_processed") &&
        trimmedLower.includes("returning")
      ) {
        if (claimGiven) {
          claimGiven = false;
          return Promise.resolve({
            rows: [{ chat_id: params?.[0], agent: params?.[1], status: "received" }],
          });
        }
        return Promise.resolve({ rows: [] });
      }

      if (trimmedLower.startsWith("select agent_chat_is_muted")) {
        return Promise.resolve({ rows: [{ muted: options.isMuted ?? false }] });
      }

      if (trimmedLower.startsWith("select * from agent_chat_pending_alerts")) {
        return Promise.resolve({ rows: options.pendingAlerts ?? [] });
      }

      if (trimmedLower.startsWith("select agent_chat_mark_alerts_seen")) {
        return Promise.resolve({ rows: [{ count: 1 }] });
      }

      if (trimmedLower.startsWith("select send_agent_message")) {
        return Promise.resolve({ rows: [{ id: options.sendReturns ?? 123 }] });
      }

      if (trimmedLower.startsWith("select mark_agent_chat_status")) {
        return Promise.resolve({ rows: [{ applied_ids: options.markApplied ?? [] }] });
      }

      if (trimmedLower.startsWith("select agent_chat_mute_peer")) {
        return Promise.resolve({
          rows: [{ muted_until: options.muteReturns ?? new Date("2026-12-01T00:00:00Z") }],
        });
      }

      if (trimmedLower.startsWith("select agent_chat_unmute_peer")) {
        return Promise.resolve({ rows: [{ unmuted: options.unmuteReturns ?? true }] });
      }

      if (trimmedLower.startsWith("update agent_chat_processed")) {
        return Promise.resolve({ rows: [] });
      }

      if (trimmedLower.startsWith("select 1")) {
        return Promise.resolve({ rows: [{ "?column?": 1 }] });
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
    log: {
      info: () => {},
      error: () => {},
      debug: () => {},
    },
    account: { config: { pollIntervalMs: 1000 } },
    cfg: {} as OpenClawConfig,
  };
}

function makeBaseRuntime(): PluginRuntime {
  return {
    channel: {
      reply: {
        resolveEnvelopeFormatOptions: () => ({}),
        formatInboundEnvelope(input: { body: string; from: string }) {
          return `${input.from}: ${input.body}`;
        },
        formatAgentEnvelope(input: { body: string; from: string }) {
          return input.body;
        },
        finalizeInboundContext(ctx: Record<string, unknown>) {
          return ctx;
        },
        createReplyDispatcherWithTyping({ deliver, onError }: Record<string, unknown>) {
          return {
            dispatcher: { waitForIdle: async () => {} },
            replyOptions: {},
            markDispatchIdle: () => {},
          };
        },
        dispatchReplyFromConfig: async (_args: Record<string, unknown>) => {
          // no-op success
        },
      },
    },
  } as unknown as PluginRuntime;
}

function findRoutedUpdate(queries: Array<{ sql: string; params: unknown[] }>, chatId: number) {
  return queries.find(
    (q) =>
      q.sql.trim().toLowerCase().startsWith("update agent_chat_processed") &&
      q.sql.toLowerCase().includes("set status = 'routed'") &&
      q.params[0] === chatId,
  );
}

function findFailedUpdate(queries: Array<{ sql: string; params: unknown[] }>, chatId: number) {
  return queries.find(
    (q) =>
      q.sql.trim().toLowerCase().startsWith("update agent_chat_processed") &&
      q.sql.toLowerCase().includes("set status = 'failed'") &&
      q.params[0] === chatId,
  );
}

// ---------------------------------------------------------------------------
// Group F: wake line
// ---------------------------------------------------------------------------

describe("F01: wake line format", () => {
  it("contains message id, sender, and tool instructions", () => {
    const line = buildWakeLine(42, "nova", false);
    assert.match(line, /agent_chat #42 from nova/);
    assert.match(line, /Nothing you write here is sent automatically/);
    assert.match(line, /agent_chat_send\(\{to:'nova', text, replyTo:42\}\)/);
    assert.match(line, /agent_chat_mark\(\{ids:\[42\], status:'handled'\}\)/);
    assert.match(line, /or 'skipped'/);
    assert.doesNotMatch(line, /broadcast/);
  });
});

describe("F02: broadcast wake line", () => {
  it("notes that the message is a broadcast", () => {
    const line = buildWakeLine(42, "nova", true);
    assert.match(line, /agent_chat #42 from nova \(broadcast\)/);
  });
});

// ---------------------------------------------------------------------------
// Group G: per-peer sessions
// ---------------------------------------------------------------------------

describe("G01: sanitizeSessionPeer", () => {
  it("lowercases and replaces disallowed characters with underscores", () => {
    assert.strictEqual(sanitizeSessionPeer("NOVA"), "nova");
    assert.strictEqual(sanitizeSessionPeer("new.hart"), "new_hart");
    assert.strictEqual(sanitizeSessionPeer("agent:foo"), "agent_foo");
    assert.strictEqual(sanitizeSessionPeer("bot@example.com"), "bot_example_com");
    assert.strictEqual(sanitizeSessionPeer("valid-Name_123"), "valid-name_123");
  });
});

describe("G02: buildSessionLabel", () => {
  it("uses agent:<self>:agent_chat:<peer> format", () => {
    assert.strictEqual(
      buildSessionLabel({ agentName: "newhart", peer: "NOVA" }),
      "agent:newhart:agent_chat:nova",
    );
  });
});

describe("G03: inbound dispatch uses per-peer session key", () => {
  it("passes the sanitized per-peer session key to finalizeInboundContext", async () => {
    const runtime = makeBaseRuntime();
    let capturedCtx: Record<string, unknown> | undefined;
    (runtime.channel!.reply as Record<string, unknown>).finalizeInboundContext = (
      ctx: Record<string, unknown>,
    ) => {
      capturedCtx = ctx;
      return ctx;
    };
    setAgentChatRuntime(runtime);

    const fakeClient = makeFakeClient();
    const fakeCtx = makeFakeCtx();

    await processAgentChatMessage({
      message: SAMPLE_MESSAGE,
      client: fakeClient as unknown as import("pg").Client,
      dbUser: "newhart",
      gatewayAgentId: "newhart",
      cfg: fakeCtx.cfg,
      ctx: fakeCtx as unknown as Parameters<typeof processAgentChatMessage>[0]["ctx"],
    });

    assert.strictEqual(
      capturedCtx?.SessionKey,
      "agent:newhart:agent_chat:nova",
    );
  });
});

describe("G04: session key uses gateway agent id while DB ops use DB user", () => {
  it("dispatches under the gateway agent id and claims rows under the DB role", async () => {
    const runtime = makeBaseRuntime();
    let capturedCtx: Record<string, unknown> | undefined;
    (runtime.channel!.reply as Record<string, unknown>).finalizeInboundContext = (
      ctx: Record<string, unknown>,
    ) => {
      capturedCtx = ctx;
      return ctx;
    };
    setAgentChatRuntime(runtime);

    const fakeClient = makeFakeClient();
    const fakeCtx = makeFakeCtx();

    await processAgentChatMessage({
      message: SAMPLE_MESSAGE,
      client: fakeClient as unknown as import("pg").Client,
      dbUser: "nova-staging",
      gatewayAgentId: "main",
      cfg: fakeCtx.cfg,
      ctx: fakeCtx as unknown as Parameters<typeof processAgentChatMessage>[0]["ctx"],
    });

    // Dispatch session ownership must use the gateway agent id, not the DB role.
    assert.strictEqual(capturedCtx?.SessionKey, "agent:main:agent_chat:nova");

    // The processed-row claim must record the DB role so the bus state stays
    // consistent with send_agent_message() provenance.
    const claimQuery = fakeClient.queries.find((q) =>
      q.sql.trim().toLowerCase().startsWith("insert into public.agent_chat_processed") &&
      q.sql.toLowerCase().includes("returning"),
    );
    assert.ok(claimQuery, "expected a claim INSERT");
    assert.strictEqual(claimQuery.params[1], "nova-staging");

    const routedUpdate = findRoutedUpdate(fakeClient.queries, SAMPLE_MESSAGE.id);
    assert.ok(routedUpdate, "expected a routed status update");
    assert.strictEqual(routedUpdate.params[1], "nova-staging");
  });
});

// ---------------------------------------------------------------------------
// Group H: broadcast
// ---------------------------------------------------------------------------

describe("H01: broadcast message uses group chat type", () => {
  it("sets ChatType to group when recipients include '*', and wake line says broadcast", async () => {
    const runtime = makeBaseRuntime();
    let capturedCtx: Record<string, unknown> | undefined;
    (runtime.channel!.reply as Record<string, unknown>).finalizeInboundContext = (
      ctx: Record<string, unknown>,
    ) => {
      capturedCtx = ctx;
      return ctx;
    };
    setAgentChatRuntime(runtime);

    const fakeClient = makeFakeClient();
    const fakeCtx = makeFakeCtx();

    await processAgentChatMessage({
      message: { ...SAMPLE_MESSAGE, recipients: ["*"] },
      client: fakeClient as unknown as import("pg").Client,
      dbUser: "newhart",
      gatewayAgentId: "newhart",
      cfg: fakeCtx.cfg,
      ctx: fakeCtx as unknown as Parameters<typeof processAgentChatMessage>[0]["ctx"],
    });

    assert.strictEqual(capturedCtx?.ChatType, "group");
    assert.match(String(capturedCtx?.Body), /\(broadcast\)/);
  });
});

// ---------------------------------------------------------------------------
// Group A: no auto-reply / explicit sends only
// ---------------------------------------------------------------------------

describe("A01: deliver() never calls send_agent_message", () => {
  it("logs the deliver payload but does not insert into agent_chat", async () => {
    const runtime = makeBaseRuntime();
    (runtime.channel!.reply as Record<string, unknown>).createReplyDispatcherWithTyping =
      ({ deliver }: Record<string, unknown>) => {
        return {
          dispatcher: {
            waitForIdle: async () => {
              await (deliver as (payload: { text: string }) => Promise<void>)({
                text: "final reply",
              });
            },
          },
          replyOptions: {},
          markDispatchIdle: () => {},
        };
      };
    setAgentChatRuntime(runtime);

    const fakeClient = makeFakeClient();
    const fakeCtx = makeFakeCtx();

    await processAgentChatMessage({
      message: SAMPLE_MESSAGE,
      client: fakeClient as unknown as import("pg").Client,
      dbUser: "newhart",
      gatewayAgentId: "newhart",
      cfg: fakeCtx.cfg,
      ctx: fakeCtx as unknown as Parameters<typeof processAgentChatMessage>[0]["ctx"],
    });

    const sendQuery = fakeClient.queries.find((q) =>
      q.sql.trim().toLowerCase().startsWith("select send_agent_message"),
    );
    assert.ok(!sendQuery, "deliver() must not insert an outbound message");
    assert.ok(findRoutedUpdate(fakeClient.queries, SAMPLE_MESSAGE.id));
  });
});

describe("A02: empty turn output is suppressed", () => {
  it("does not send empty deliver payload", async () => {
    const runtime = makeBaseRuntime();
    (runtime.channel!.reply as Record<string, unknown>).createReplyDispatcherWithTyping =
      ({ deliver }: Record<string, unknown>) => {
        return {
          dispatcher: {
            waitForIdle: async () => {
              await (deliver as (payload: { text: string }) => Promise<void>)({ text: "" });
            },
          },
          replyOptions: {},
          markDispatchIdle: () => {},
        };
      };
    setAgentChatRuntime(runtime);

    const fakeClient = makeFakeClient();
    const fakeCtx = makeFakeCtx();

    await processAgentChatMessage({
      message: SAMPLE_MESSAGE,
      client: fakeClient as unknown as import("pg").Client,
      dbUser: "newhart",
      gatewayAgentId: "newhart",
      cfg: fakeCtx.cfg,
      ctx: fakeCtx as unknown as Parameters<typeof processAgentChatMessage>[0]["ctx"],
    });

    const sendQuery = fakeClient.queries.find((q) =>
      q.sql.trim().toLowerCase().startsWith("select send_agent_message"),
    );
    assert.ok(!sendQuery);
    assert.ok(findRoutedUpdate(fakeClient.queries, SAMPLE_MESSAGE.id));
  });
});

describe("A03: NO_REPLY token is suppressed", () => {
  it("does not send the literal NO_REPLY token", async () => {
    const runtime = makeBaseRuntime();
    (runtime.channel!.reply as Record<string, unknown>).createReplyDispatcherWithTyping =
      ({ deliver }: Record<string, unknown>) => {
        return {
          dispatcher: {
            waitForIdle: async () => {
              await (deliver as (payload: { text: string }) => Promise<void>)({ text: "NO_REPLY" });
            },
          },
          replyOptions: {},
          markDispatchIdle: () => {},
        };
      };
    setAgentChatRuntime(runtime);

    const fakeClient = makeFakeClient();
    const fakeCtx = makeFakeCtx();

    await processAgentChatMessage({
      message: SAMPLE_MESSAGE,
      client: fakeClient as unknown as import("pg").Client,
      dbUser: "newhart",
      gatewayAgentId: "newhart",
      cfg: fakeCtx.cfg,
      ctx: fakeCtx as unknown as Parameters<typeof processAgentChatMessage>[0]["ctx"],
    });

    const sendQuery = fakeClient.queries.find((q) =>
      q.sql.trim().toLowerCase().startsWith("select send_agent_message"),
    );
    assert.ok(!sendQuery);
  });
});

describe("A04: ANNOUNCE_SKIP token is suppressed", () => {
  it("does not send the literal ANNOUNCE_SKIP token", async () => {
    const runtime = makeBaseRuntime();
    (runtime.channel!.reply as Record<string, unknown>).createReplyDispatcherWithTyping =
      ({ deliver }: Record<string, unknown>) => {
        return {
          dispatcher: {
            waitForIdle: async () => {
              await (deliver as (payload: { text: string }) => Promise<void>)({
                text: "ANNOUNCE_SKIP",
              });
            },
          },
          replyOptions: {},
          markDispatchIdle: () => {},
        };
      };
    setAgentChatRuntime(runtime);

    const fakeClient = makeFakeClient();
    const fakeCtx = makeFakeCtx();

    await processAgentChatMessage({
      message: SAMPLE_MESSAGE,
      client: fakeClient as unknown as import("pg").Client,
      dbUser: "newhart",
      gatewayAgentId: "newhart",
      cfg: fakeCtx.cfg,
      ctx: fakeCtx as unknown as Parameters<typeof processAgentChatMessage>[0]["ctx"],
    });

    const sendQuery = fakeClient.queries.find((q) =>
      q.sql.trim().toLowerCase().startsWith("select send_agent_message"),
    );
    assert.ok(!sendQuery);
  });
});

describe("A05: fallback summary is suppressed", () => {
  it("does not send the gateway fallback text", async () => {
    const runtime = makeBaseRuntime();
    (runtime.channel!.reply as Record<string, unknown>).createReplyDispatcherWithTyping =
      ({ deliver }: Record<string, unknown>) => {
        return {
          dispatcher: {
            waitForIdle: async () => {
              await (deliver as (payload: { text: string }) => Promise<void>)({
                text: "The tool run finished, but no final summary was produced",
              });
            },
          },
          replyOptions: {},
          markDispatchIdle: () => {},
        };
      };
    setAgentChatRuntime(runtime);

    const fakeClient = makeFakeClient();
    const fakeCtx = makeFakeCtx();

    await processAgentChatMessage({
      message: SAMPLE_MESSAGE,
      client: fakeClient as unknown as import("pg").Client,
      dbUser: "newhart",
      gatewayAgentId: "newhart",
      cfg: fakeCtx.cfg,
      ctx: fakeCtx as unknown as Parameters<typeof processAgentChatMessage>[0]["ctx"],
    });

    const sendQuery = fakeClient.queries.find((q) =>
      q.sql.trim().toLowerCase().startsWith("select send_agent_message"),
    );
    assert.ok(!sendQuery);
  });
});

describe("A12: origin route is closed (no deliverable agent_chat target)", () => {
  it("inbound message context has no To/OriginatingTo", async () => {
    const runtime = makeBaseRuntime();
    let capturedCtx: Record<string, unknown> | undefined;
    (runtime.channel!.reply as Record<string, unknown>).finalizeInboundContext = (
      ctx: Record<string, unknown>,
    ) => {
      capturedCtx = ctx;
      return ctx;
    };
    setAgentChatRuntime(runtime);

    const fakeClient = makeFakeClient();
    const fakeCtx = makeFakeCtx();

    await processAgentChatMessage({
      message: SAMPLE_MESSAGE,
      client: fakeClient as unknown as import("pg").Client,
      dbUser: "newhart",
      gatewayAgentId: "newhart",
      cfg: fakeCtx.cfg,
      ctx: fakeCtx as unknown as Parameters<typeof processAgentChatMessage>[0]["ctx"],
    });

    assert.strictEqual(capturedCtx?.OriginatingChannel, "agent_chat");
    assert.ok(
      capturedCtx?.OriginatingTo === undefined || capturedCtx?.OriginatingTo === null,
      "OriginatingTo must be absent",
    );
    assert.ok(
      capturedCtx?.To === undefined || capturedCtx?.To === null,
      "To must be absent so the stored delivery context has no deliverable agent_chat target",
    );
  });

  it("breaker alert context has no To/OriginatingTo", async () => {
    const runtime = makeBaseRuntime();
    let capturedCtx: Record<string, unknown> | undefined;
    (runtime.channel!.reply as Record<string, unknown>).finalizeInboundContext = (
      ctx: Record<string, unknown>,
    ) => {
      capturedCtx = ctx;
      return ctx;
    };
    setAgentChatRuntime(runtime);

    const fakeClient = makeFakeClient();
    const fakeCtx = makeFakeCtx();

    const alert = {
      alert_id: 7,
      pair_a: "newhart",
      pair_b: "nova",
      window_start: new Date("2026-10-02T19:00:00Z"),
      window_end: new Date("2026-10-02T19:05:00Z"),
      message_count: 6,
      threshold: 6,
      created_at: new Date("2026-10-02T19:05:00Z"),
    };

    await injectBreakerAlert({
      alert,
      client: fakeClient as unknown as import("pg").Client,
      dbUser: "newhart",
      gatewayAgentId: "newhart",
      cfg: fakeCtx.cfg,
      ctx: fakeCtx as unknown as Parameters<typeof processAgentChatMessage>[0]["ctx"],
      runtime,
    });

    assert.strictEqual(capturedCtx?.OriginatingChannel, "agent_chat");
    assert.ok(
      capturedCtx?.OriginatingTo === undefined || capturedCtx?.OriginatingTo === null,
    );
    assert.ok(
      capturedCtx?.To === undefined || capturedCtx?.To === null,
    );
  });

  it("startup digest context has no To/OriginatingTo", async () => {
    const runtime = makeBaseRuntime();
    let capturedCtx: Record<string, unknown> | undefined;
    (runtime.channel!.reply as Record<string, unknown>).finalizeInboundContext = (
      ctx: Record<string, unknown>,
    ) => {
      capturedCtx = ctx;
      return ctx;
    };
    setAgentChatRuntime(runtime);

    await deliverDigest({
      runtime,
      cfg: runtime.cfg ?? ({} as OpenClawConfig),
      agentName: "newhart",
      digestText: "test digest",
    });

    assert.strictEqual(capturedCtx?.OriginatingChannel, "agent_chat");
    assert.ok(
      capturedCtx?.OriginatingTo === undefined || capturedCtx?.OriginatingTo === null,
    );
    assert.ok(
      capturedCtx?.To === undefined || capturedCtx?.To === null,
    );
  });
});

// ---------------------------------------------------------------------------
// Group E: lifecycle with no auto-mark
// ---------------------------------------------------------------------------

describe("E01: successful dispatch marks routed", () => {
  it("updates status to routed and stops there", async () => {
    const runtime = makeBaseRuntime();
    setAgentChatRuntime(runtime);

    const fakeClient = makeFakeClient();
    const fakeCtx = makeFakeCtx();

    await processAgentChatMessage({
      message: SAMPLE_MESSAGE,
      client: fakeClient as unknown as import("pg").Client,
      dbUser: "newhart",
      gatewayAgentId: "newhart",
      cfg: fakeCtx.cfg,
      ctx: fakeCtx as unknown as Parameters<typeof processAgentChatMessage>[0]["ctx"],
    });

    assert.ok(findRoutedUpdate(fakeClient.queries, SAMPLE_MESSAGE.id));
    const failedUpdate = findFailedUpdate(fakeClient.queries, SAMPLE_MESSAGE.id);
    assert.ok(!failedUpdate);
  });
});

// ---------------------------------------------------------------------------
// Mute check
// ---------------------------------------------------------------------------

describe("I01: muted peer suppresses wake", () => {
  it("checks agent_chat_is_muted, logs, and leaves message routed without dispatch", async () => {
    const runtime = makeBaseRuntime();
    let dispatched = false;
    (runtime.channel!.reply as Record<string, unknown>).dispatchReplyFromConfig = async () => {
      dispatched = true;
    };
    setAgentChatRuntime(runtime);

    const fakeClient = makeFakeClient({ isMuted: true });
    const fakeCtx = makeFakeCtx();

    await processAgentChatMessage({
      message: SAMPLE_MESSAGE,
      client: fakeClient as unknown as import("pg").Client,
      dbUser: "newhart",
      gatewayAgentId: "newhart",
      cfg: fakeCtx.cfg,
      ctx: fakeCtx as unknown as Parameters<typeof processAgentChatMessage>[0]["ctx"],
    });

    assert.strictEqual(dispatched, false);
    const muteQuery = fakeClient.queries.find((q) =>
      q.sql.trim().toLowerCase().startsWith("select agent_chat_is_muted"),
    );
    assert.ok(muteQuery);
    assert.ok(findRoutedUpdate(fakeClient.queries, SAMPLE_MESSAGE.id));
  });
});

// ---------------------------------------------------------------------------
// Breaker alert injection
// ---------------------------------------------------------------------------

describe("I02: breaker alert injected into per-peer session", () => {
  it("marks alert seen and dispatches a wake for the peer", async () => {
    const runtime = makeBaseRuntime();
    let capturedCtx: Record<string, unknown> | undefined;
    (runtime.channel!.reply as Record<string, unknown>).finalizeInboundContext = (
      ctx: Record<string, unknown>,
    ) => {
      capturedCtx = ctx;
      return ctx;
    };
    setAgentChatRuntime(runtime);

    const fakeClient = makeFakeClient();
    const fakeCtx = makeFakeCtx();

    const alert = {
      alert_id: 7,
      pair_a: "newhart",
      pair_b: "nova",
      window_start: new Date("2026-10-02T19:00:00Z"),
      window_end: new Date("2026-10-02T19:05:00Z"),
      message_count: 6,
      threshold: 6,
      created_at: new Date("2026-10-02T19:05:00Z"),
    };

    await injectBreakerAlert({
      alert,
      client: fakeClient as unknown as import("pg").Client,
      dbUser: "newhart",
      gatewayAgentId: "newhart",
      cfg: fakeCtx.cfg,
      ctx: fakeCtx as unknown as Parameters<typeof processAgentChatMessage>[0]["ctx"],
      runtime,
    });

    const seenQuery = fakeClient.queries.find((q) =>
      q.sql.trim().toLowerCase().startsWith("select agent_chat_mark_alerts_seen"),
    );
    assert.ok(seenQuery);
    assert.deepStrictEqual(seenQuery?.params[0], [7]);

    assert.strictEqual(
      capturedCtx?.SessionKey,
      "agent:newhart:agent_chat:nova",
    );
    assert.match(String(capturedCtx?.Body), /Loop check:/);
    assert.match(String(capturedCtx?.Body), /you and nova exchanged 6 agent_chat messages/);
    assert.match(String(capturedCtx?.Body), /agent_chat_mute/);
  });

  it("does NOT mark alert seen when dispatch fails", async () => {
    const runtime = makeBaseRuntime();
    (runtime.channel!.reply as Record<string, unknown>).dispatchReplyFromConfig =
      async () => {
        throw new Error("prepared reply dispatch runtime owner was not published");
      };
    setAgentChatRuntime(runtime);

    const fakeClient = makeFakeClient();
    const fakeCtx = makeFakeCtx();

    const alert = {
      alert_id: 8,
      pair_a: "newhart",
      pair_b: "nova",
      window_start: new Date("2026-10-02T19:00:00Z"),
      window_end: new Date("2026-10-02T19:05:00Z"),
      message_count: 6,
      threshold: 6,
      created_at: new Date("2026-10-02T19:05:00Z"),
    };

    await injectBreakerAlert({
      alert,
      client: fakeClient as unknown as import("pg").Client,
      dbUser: "newhart",
      gatewayAgentId: "newhart",
      cfg: fakeCtx.cfg,
      ctx: fakeCtx as unknown as Parameters<typeof processAgentChatMessage>[0]["ctx"],
      runtime,
    });

    const seenQuery = fakeClient.queries.find((q) =>
      q.sql.trim().toLowerCase().startsWith("select agent_chat_mark_alerts_seen"),
    );
    assert.ok(!seenQuery, "alert must stay unseen when dispatch fails");
  });
});

// ---------------------------------------------------------------------------
// Group B: agent_chat_send tool
// ---------------------------------------------------------------------------

describe("B01: agent_chat_send factory opts out for sandboxed sessions", () => {
  it("returns null when toolContext.sandboxed is true", () => {
    const factory = createAgentChatTools({
      createClient: () => ({}) as import("pg").Client,
      resolveDbUser: () => "newhart",
    });
    assert.strictEqual(factory({ sandboxed: true }), null);
  });
});

describe("B02: agent_chat_send sends to a single peer", () => {
  it("calls send_agent_message with lowercased recipient and replyTo", async () => {
    const factory = createAgentChatTools({
      createClient: () => makeFakeClient({ sendReturns: 99 }) as unknown as import("pg").Client,
      resolveDbUser: () => "newhart",
    });
    const tools = factory({})!;
    const sendTool = tools.find((t) => t.name === "agent_chat_send")!;
    const result = await sendTool.execute("call-1", { to: "NOVA", text: "hello", replyTo: 42 });
    const details = result.details as { id: number };
    assert.strictEqual(details.id, 99);
  });
});

describe("B03: agent_chat_send broadcasts with '*', returning suppressed on null", () => {
  it("uses '*' recipient array and reports suppression when DB returns null", async () => {
    let capturedParams: unknown[] | undefined;
    const fakeClient = {
      connect: async () => {},
      end: async () => {},
      query: async (sql: string, params?: unknown[]) => {
        capturedParams = params;
        return { rows: [{ id: null }] };
      },
    };
    const factory = createAgentChatTools({
      createClient: () => fakeClient as unknown as import("pg").Client,
      resolveDbUser: () => "newhart",
    });
    const tools = factory({})!;
    const sendTool = tools.find((t) => t.name === "agent_chat_send")!;
    const result = await sendTool.execute("call-1", { to: "*", text: "broadcast" });
    const details = result.details as { suppressed: boolean; reason: string };
    assert.strictEqual(details.suppressed, true);
    assert.deepStrictEqual(capturedParams?.[2], ["*"]);
  });
});

// ---------------------------------------------------------------------------
// Group D (via agent_chat_mark tool)
// ---------------------------------------------------------------------------

describe("D01: agent_chat_mark returns applied and notApplied", () => {
  it("maps mark_agent_chat_status result to applied/notApplied arrays", async () => {
    const factory = createAgentChatTools({
      createClient: () =>
        makeFakeClient({ markApplied: [BigInt(1), BigInt(3)] }) as unknown as import("pg").Client,
      resolveDbUser: () => "newhart",
    });
    const tools = factory({})!;
    const markTool = tools.find((t) => t.name === "agent_chat_mark")!;
    const result = await markTool.execute("call-1", {
      ids: [1, 2, 3],
      status: "handled",
    });
    const details = result.details as { applied: number[]; notApplied: number[] };
    assert.deepStrictEqual(details.applied, [1, 3]);
    assert.deepStrictEqual(details.notApplied, [2]);
  });
});

// ---------------------------------------------------------------------------
// Group K: manifest / tools
// ---------------------------------------------------------------------------

describe("K01: manifest declares tool contracts", () => {
  it("lists agent_chat_send, agent_chat_mark, agent_chat_mute in contracts.tools", () => {
    const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf-8"));
    assert.ok(Array.isArray(manifest.contracts?.tools));
    assert.ok(manifest.contracts.tools.includes("agent_chat_send"));
    assert.ok(manifest.contracts.tools.includes("agent_chat_mark"));
    assert.ok(manifest.contracts.tools.includes("agent_chat_mute"));
  });
});

describe("K02: manifest no longer exposes routeToSession", () => {
  it("channelConfigs and configSchema do not contain routeToSession", () => {
    const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf-8"));
    const channelProps = manifest.channelConfigs?.agent_chat?.schema?.properties ?? {};
    const configProps = manifest.configSchema?.properties ?? {};
    assert.ok(!("routeToSession" in channelProps));
    assert.ok(!("routeToSession" in configProps));
  });
});

// ---------------------------------------------------------------------------
// Group L: build / lint / test (sanity assertions, real commands run in CI)
// ---------------------------------------------------------------------------

describe("L03-L04: build and lint sanity", () => {
  it("manifest and source files exist", () => {
    assert.ok(fs.existsSync(manifestPath));
    assert.ok(fs.existsSync(path.join(__dirname, "..", "src", "tools.ts")));
    assert.ok(fs.existsSync(path.join(__dirname, "..", "src", "channel.ts")));
  });
});

// ---------------------------------------------------------------------------
// SE #1453 Fix Loop 7 additions
// ---------------------------------------------------------------------------

function makeRecordingFakeClient(options: {
  sendReturns?: number | null;
  markApplied?: bigint[];
} = {}): {
  queries: Array<{ sql: string; params: unknown[] }>;
  connect: () => Promise<void>;
  end: () => Promise<void>;
  query: (sql: string, params?: unknown[]) => Promise<{ rows: unknown[] }>;
} {
  const queries: Array<{ sql: string; params: unknown[] }> = [];
  return {
    queries,
    connect: async () => {},
    end: async () => {},
    query(sql: string, params?: unknown[]) {
      queries.push({ sql, params: params ?? [] });
      const trimmedLower = sql.trim().toLowerCase();
      if (trimmedLower.startsWith("select send_agent_message")) {
        return Promise.resolve({ rows: [{ id: options.sendReturns ?? 123 }] });
      }
      if (trimmedLower.startsWith("select mark_agent_chat_status")) {
        return Promise.resolve({ rows: [{ applied_ids: options.markApplied ?? [] }] });
      }
      return Promise.resolve({ rows: [] });
    },
  };
}

function makeDeliverRecordingRuntime(deliverPayloads: unknown[] = []): PluginRuntime {
  return {
    channel: {
      reply: {
        resolveEnvelopeFormatOptions: () => ({}),
        formatInboundEnvelope(input: { body: string; from: string }) {
          return `${input.from}: ${input.body}`;
        },
        formatAgentEnvelope(input: { body: string; from: string }) {
          return input.body;
        },
        finalizeInboundContext(ctx: Record<string, unknown>) {
          return ctx;
        },
        createReplyDispatcherWithTyping({ deliver, onError }: Record<string, unknown>) {
          return {
            dispatcher: {
              waitForIdle: async () => {
                for (const payload of deliverPayloads) {
                  await (deliver as (payload: { text: string }) => Promise<void>)(
                    payload as { text: string },
                  );
                }
              },
            },
            replyOptions: {},
            markDispatchIdle: () => {},
          };
        },
        dispatchReplyFromConfig: async (_args: Record<string, unknown>) => {
          // no-op success
        },
      },
    },
  } as unknown as PluginRuntime;
}

// ─── Group C-E2E: ruling C / D5 — no implicit auto-reply reaches agent_chat ───

describe("C-E2E-01: deliver() with subagent-completion-style payload never writes agent_chat", () => {
  it("logs the deliver payload but records zero send_agent_message queries", async () => {
    const runtime = makeDeliverRecordingRuntime([
      { text: "[subagent] Task finished: summary here" },
    ]);
    setAgentChatRuntime(runtime);

    const fakeClient = makeFakeClient();
    const fakeCtx = makeFakeCtx();

    await processAgentChatMessage({
      message: SAMPLE_MESSAGE,
      client: fakeClient as unknown as import("pg").Client,
      dbUser: "newhart",
      gatewayAgentId: "newhart",
      cfg: fakeCtx.cfg,
      ctx: fakeCtx as unknown as Parameters<typeof processAgentChatMessage>[0]["ctx"],
    });

    const sendQueries = fakeClient.queries.filter((q) =>
      q.sql.trim().toLowerCase().startsWith("select send_agent_message"),
    );
    const insertQueries = fakeClient.queries.filter((q) =>
      /insert into public\.agent_chat\b/i.test(q.sql),
    );
    assert.strictEqual(sendQueries.length, 0, "deliver() must not call send_agent_message");
    assert.strictEqual(insertQueries.length, 0, "deliver() must not INSERT into agent_chat");
    assert.ok(findRoutedUpdate(fakeClient.queries, SAMPLE_MESSAGE.id), "message should be marked routed");
  });
});

describe("C-E2E-02: explicit outbound.sendText is the legitimate row-producing path", () => {
  it("insertOutboundMessage calls send_agent_message with correct sender and recipient", async () => {
    const fakeClient = makeRecordingFakeClient({ sendReturns: 99 });

    await insertOutboundMessage(fakeClient as unknown as import("pg").Client, {
      sender: "newhart",
      message: "explicit send",
      recipients: ["nova"],
      replyTo: null,
    });

    const sendQuery = fakeClient.queries.find((q) =>
      q.sql.trim().toLowerCase().startsWith("select send_agent_message"),
    );
    assert.ok(sendQuery, "insertOutboundMessage must call send_agent_message");
    assert.strictEqual(sendQuery.params[0], "newhart");
    assert.strictEqual(sendQuery.params[1], "explicit send");
    assert.deepStrictEqual(sendQuery.params[2], ["nova"]);
    assert.strictEqual(sendQuery.params[4], null);
  });
});

describe("C-E2E-03: breaker-alert context has no deliverable agent_chat route", () => {
  it("finalizeInboundContext payload omits OriginatingTo/To and a fake announce resolver returns no route", async () => {
    const runtime = makeBaseRuntime();
    let capturedCtx: Record<string, unknown> | undefined;
    (runtime.channel!.reply as Record<string, unknown>).finalizeInboundContext = (
      ctx: Record<string, unknown>,
    ) => {
      capturedCtx = ctx;
      return ctx;
    };
    setAgentChatRuntime(runtime);

    const fakeClient = makeFakeClient();
    const fakeCtx = makeFakeCtx();

    const alert = {
      alert_id: 9,
      pair_a: "newhart",
      pair_b: "nova",
      window_start: new Date("2026-10-02T19:00:00Z"),
      window_end: new Date("2026-10-02T19:05:00Z"),
      message_count: 6,
      threshold: 6,
      created_at: new Date("2026-10-02T19:05:00Z"),
    };

    await injectBreakerAlert({
      alert,
      client: fakeClient as unknown as import("pg").Client,
      dbUser: "newhart",
      gatewayAgentId: "newhart",
      cfg: fakeCtx.cfg,
      ctx: fakeCtx as unknown as Parameters<typeof processAgentChatMessage>[0]["ctx"],
      runtime,
    });

    assert.strictEqual(capturedCtx?.OriginatingChannel, "agent_chat");
    assert.ok(
      capturedCtx?.OriginatingTo === undefined || capturedCtx?.OriginatingTo === null,
      "OriginatingTo must be absent",
    );
    assert.ok(capturedCtx?.To === undefined || capturedCtx?.To === null, "To must be absent");

    // Stand-in for gateway-core announce-target resolution. The real SDK
    // function (resolveAnnounceTarget in openclaw/plugin-sdk/agents/tools/sessions-announce-target)
    // is not exported from the public entry point, so this fake replicates the
    // documented behavior: no route when sessionKey lacks a deliverable origin.
    function fakeResolveAnnounceTarget(ctx: Record<string, unknown>): { target: string } | undefined {
      const to = (typeof ctx.OriginatingTo === "string" ? ctx.OriginatingTo : ctx.To)?.trim();
      if (!to) return undefined;
      return { target: to };
    }

    assert.strictEqual(
      fakeResolveAnnounceTarget(capturedCtx!),
      undefined,
      "no deliverable route should resolve for breaker alert payload",
    );
  });
});

describe("C-E2E-04: processAgentChatMessage and injectBreakerAlert deliver closures do not reference insertOutboundMessage", () => {
  it("source inspection shows neither deliver closure can call insertOutboundMessage or createPgClient", () => {
    const channelSource = fs.readFileSync(
      path.join(__dirname, "..", "src", "channel.ts"),
      "utf-8",
    );

    // Helper: find the first `deliver:` arrow function inside a named function.
    function extractFirstDeliverClosure(functionName: string): string {
      const funcStart = channelSource.indexOf(`async function ${functionName}`);
      assert.ok(funcStart >= 0, `could not locate ${functionName}`);
      const deliverStart = channelSource.indexOf("deliver:", funcStart);
      assert.ok(deliverStart >= 0, `could not locate deliver: in ${functionName}`);
      // Walk braces from the arrow-function body start to find the matching close.
      const arrowMatch = channelSource.slice(deliverStart).match(/deliver:\s*async\s*\([^)]*\)\s*=>\s*\{/);
      assert.ok(arrowMatch, `could not parse deliver arrow function in ${functionName}`);
      let braceStart = deliverStart + arrowMatch[0].length - 1; // position of '{'
      let depth = 0;
      let pos = braceStart;
      while (pos < channelSource.length) {
        const ch = channelSource[pos];
        if (ch === "{") depth++;
        else if (ch === "}") {
          depth--;
          if (depth === 0) {
            return channelSource.slice(braceStart, pos + 1);
          }
        }
        pos++;
      }
      assert.fail(`could not find matching brace for deliver closure in ${functionName}`);
    }

    const processClosure = extractFirstDeliverClosure("processAgentChatMessage");
    assert.ok(
      !processClosure.includes("insertOutboundMessage"),
      "processAgentChatMessage deliver closure must not reference insertOutboundMessage",
    );
    assert.ok(
      !processClosure.includes("createPgClient"),
      "processAgentChatMessage deliver closure must not reference createPgClient",
    );

    const alertClosure = extractFirstDeliverClosure("injectBreakerAlert");
    assert.ok(
      !alertClosure.includes("insertOutboundMessage"),
      "injectBreakerAlert deliver closure must not reference insertOutboundMessage",
    );
    assert.ok(
      !alertClosure.includes("createPgClient"),
      "injectBreakerAlert deliver closure must not reference createPgClient",
    );
  });
});

// ─── Group A06-A09: no-auto-reply payload-shape variants ───

describe("A06: whitespace-only deliver payload is suppressed", () => {
  it("does not call send_agent_message for whitespace/newlines only", async () => {
    const runtime = makeDeliverRecordingRuntime([{ text: "   \n\t  \n  " }]);
    setAgentChatRuntime(runtime);

    const fakeClient = makeFakeClient();
    const fakeCtx = makeFakeCtx();

    await processAgentChatMessage({
      message: SAMPLE_MESSAGE,
      client: fakeClient as unknown as import("pg").Client,
      dbUser: "newhart",
      gatewayAgentId: "newhart",
      cfg: fakeCtx.cfg,
      ctx: fakeCtx as unknown as Parameters<typeof processAgentChatMessage>[0]["ctx"],
    });

    const sendQuery = fakeClient.queries.find((q) =>
      q.sql.trim().toLowerCase().startsWith("select send_agent_message"),
    );
    assert.ok(!sendQuery);
  });
});

describe("A07: tool-call-only turn with empty text is suppressed", () => {
  it("does not write when deliver payload has no final text", async () => {
    const runtime = makeDeliverRecordingRuntime([{ text: "", toolCalls: [{ name: "foo" }] }]);
    setAgentChatRuntime(runtime);

    const fakeClient = makeFakeClient();
    const fakeCtx = makeFakeCtx();

    await processAgentChatMessage({
      message: SAMPLE_MESSAGE,
      client: fakeClient as unknown as import("pg").Client,
      dbUser: "newhart",
      gatewayAgentId: "newhart",
      cfg: fakeCtx.cfg,
      ctx: fakeCtx as unknown as Parameters<typeof processAgentChatMessage>[0]["ctx"],
    });

    const sendQuery = fakeClient.queries.find((q) =>
      q.sql.trim().toLowerCase().startsWith("select send_agent_message"),
    );
    assert.ok(!sendQuery);
  });
});

describe("A08: oversized deliver payload is suppressed without chunking", () => {
  it("records zero send_agent_message queries regardless of text size", async () => {
    const bigText = "x".repeat(10000);
    const runtime = makeDeliverRecordingRuntime([{ text: bigText }]);
    setAgentChatRuntime(runtime);

    const fakeClient = makeFakeClient();
    const fakeCtx = makeFakeCtx();

    await processAgentChatMessage({
      message: SAMPLE_MESSAGE,
      client: fakeClient as unknown as import("pg").Client,
      dbUser: "newhart",
      gatewayAgentId: "newhart",
      cfg: fakeCtx.cfg,
      ctx: fakeCtx as unknown as Parameters<typeof processAgentChatMessage>[0]["ctx"],
    });

    const sendQueries = fakeClient.queries.filter((q) =>
      q.sql.trim().toLowerCase().startsWith("select send_agent_message"),
    );
    assert.strictEqual(sendQueries.length, 0, "oversized payload must not be chunked and sent");
  });
});

describe("A09: duplicate deliver callbacks for the same message are both suppressed", () => {
  it("second deliver callback does not produce a second write attempt", async () => {
    const runtime = makeDeliverRecordingRuntime([
      { text: "first callback" },
      { text: "second callback" },
    ]);
    setAgentChatRuntime(runtime);

    const fakeClient = makeFakeClient();
    const fakeCtx = makeFakeCtx();

    await processAgentChatMessage({
      message: SAMPLE_MESSAGE,
      client: fakeClient as unknown as import("pg").Client,
      dbUser: "newhart",
      gatewayAgentId: "newhart",
      cfg: fakeCtx.cfg,
      ctx: fakeCtx as unknown as Parameters<typeof processAgentChatMessage>[0]["ctx"],
    });

    const sendQueries = fakeClient.queries.filter((q) =>
      q.sql.trim().toLowerCase().startsWith("select send_agent_message"),
    );
    assert.strictEqual(sendQueries.length, 0, "both duplicate deliver callbacks must be suppressed");
  });
});

// ─── Group E02-E05: lifecycle with no auto-mark ───

describe("E02: dispatch failure marks message failed", () => {
  it("updates status to failed and never auto-marks terminal", async () => {
    const runtime = makeBaseRuntime();
    (runtime.channel!.reply as Record<string, unknown>).dispatchReplyFromConfig = async () => {
      throw new Error("prepared reply dispatch runtime owner was not published");
    };
    setAgentChatRuntime(runtime);

    const fakeClient = makeFakeClient();
    const fakeCtx = makeFakeCtx();

    await processAgentChatMessage({
      message: SAMPLE_MESSAGE,
      client: fakeClient as unknown as import("pg").Client,
      dbUser: "newhart",
      gatewayAgentId: "newhart",
      cfg: fakeCtx.cfg,
      ctx: fakeCtx as unknown as Parameters<typeof processAgentChatMessage>[0]["ctx"],
    });

    assert.ok(findFailedUpdate(fakeClient.queries, SAMPLE_MESSAGE.id));
    const routedUpdate = findRoutedUpdate(fakeClient.queries, SAMPLE_MESSAGE.id);
    assert.ok(!routedUpdate, "failed dispatch must not be marked routed");
  });
});

describe("E03: envelope formatting failure marks message failed", () => {
  it("does not dispatch when envelope fails and records failed status", async () => {
    const runtime = makeBaseRuntime();
    let dispatched = false;
    (runtime.channel!.reply as Record<string, unknown>).formatInboundEnvelope = () => {
      throw new Error("envelope format failure");
    };
    (runtime.channel!.reply as Record<string, unknown>).formatAgentEnvelope = () => {
      throw new Error("envelope format failure");
    };
    (runtime.channel!.reply as Record<string, unknown>).dispatchReplyFromConfig = async () => {
      dispatched = true;
    };
    setAgentChatRuntime(runtime);

    const fakeClient = makeFakeClient();
    const fakeCtx = makeFakeCtx();

    await processAgentChatMessage({
      message: SAMPLE_MESSAGE,
      client: fakeClient as unknown as import("pg").Client,
      dbUser: "newhart",
      gatewayAgentId: "newhart",
      cfg: fakeCtx.cfg,
      ctx: fakeCtx as unknown as Parameters<typeof processAgentChatMessage>[0]["ctx"],
    });

    assert.strictEqual(dispatched, false, "dispatchReplyFromConfig must not be called after envelope failure");
    assert.ok(findFailedUpdate(fakeClient.queries, SAMPLE_MESSAGE.id));
  });
});

describe("E04: missing deprecated reply functions marks message failed", () => {
  it("does not call dispatchReplyFromConfig when required functions are missing", async () => {
    const runtime = makeBaseRuntime();
    let dispatched = false;
    (runtime.channel!.reply as Record<string, unknown>).finalizeInboundContext = undefined as unknown as () => Record<string, unknown>;
    (runtime.channel!.reply as Record<string, unknown>).createReplyDispatcherWithTyping = undefined as unknown as () => Record<string, unknown>;
    (runtime.channel!.reply as Record<string, unknown>).dispatchReplyFromConfig = async () => {
      dispatched = true;
    };
    setAgentChatRuntime(runtime);

    const fakeClient = makeFakeClient();
    const fakeCtx = makeFakeCtx();

    await processAgentChatMessage({
      message: SAMPLE_MESSAGE,
      client: fakeClient as unknown as import("pg").Client,
      dbUser: "newhart",
      gatewayAgentId: "newhart",
      cfg: fakeCtx.cfg,
      ctx: fakeCtx as unknown as Parameters<typeof processAgentChatMessage>[0]["ctx"],
    });

    assert.strictEqual(dispatched, false, "dispatch must not be attempted when functions are missing");
    assert.ok(findFailedUpdate(fakeClient.queries, SAMPLE_MESSAGE.id));
  });
});

describe("E05: concurrent claimMessage calls for same id return null for loser", () => {
  it("second claim returns null avoiding double-dispatch", async () => {
    const fakeClient = makeFakeClient({ claimReturns: true });
    const dbClient = fakeClient as unknown as import("pg").Client;

    const [first, second] = await Promise.all([
      claimMessage(dbClient, SAMPLE_MESSAGE.id, "newhart"),
      claimMessage(dbClient, SAMPLE_MESSAGE.id, "newhart"),
    ]);

    assert.ok(first, "first concurrent claim should win");
    assert.strictEqual(second, null, "second concurrent claim must lose the race");
  });
});

// ─── Group B04-B15: tool-schema boundary enforcement ───

function makeSchemaRecordingClient() {
  const queries: Array<{ sql: string; params: unknown[] }> = [];
  return {
    queries,
    connect: async () => {},
    end: async () => {},
    query: async (sql: string, params?: unknown[]) => {
      queries.push({ sql, params: params ?? [] });
      return { rows: [] };
    },
  };
}

describe("B04: agent_chat_send accepts text at 65536-byte boundary", () => {
  it("calls send_agent_message for 65536 UTF-8 bytes", async () => {
    // 65534 ASCII chars + 1 two-byte char = 65535 chars, 65536 bytes.
    const text = "x".repeat(65534) + "é";
    assert.strictEqual(Buffer.byteLength(text, "utf8"), 65536);
    assert.ok(Value.Check(SendParams, { to: "nova", text }));

    const fakeClient = makeSchemaRecordingClient();
    const factory = createAgentChatTools({
      createClient: () => fakeClient as unknown as import("pg").Client,
      resolveDbUser: () => "newhart",
    });
    const tools = factory({})!;
    const sendTool = tools.find((t) => t.name === "agent_chat_send")!;
    await sendTool.execute("call-1", { to: "nova", text } as any);

    const sendQuery = fakeClient.queries.find((q) =>
      q.sql.trim().toLowerCase().startsWith("select send_agent_message"),
    );
    assert.ok(sendQuery, "65536-byte text must reach send_agent_message");
  });
});

describe("B05: agent_chat_send rejects text exceeding 65536 bytes", () => {
  it("returns toolResultError and makes no DB call", async () => {
    // 65534 ASCII chars + 1 three-byte char = 65535 chars, 65537 bytes.
    const text = "x".repeat(65534) + "€";
    assert.strictEqual(Buffer.byteLength(text, "utf8"), 65537);
    assert.ok(Value.Check(SendParams, { to: "nova", text }));

    const fakeClient = makeSchemaRecordingClient();
    const factory = createAgentChatTools({
      createClient: () => fakeClient as unknown as import("pg").Client,
      resolveDbUser: () => "newhart",
    });
    const tools = factory({})!;
    const sendTool = tools.find((t) => t.name === "agent_chat_send")!;
    const result = await sendTool.execute("call-1", { to: "nova", text } as any);

    assert.deepStrictEqual(result.details, { ok: false, error: "agent_chat_send: text exceeds 65536 bytes" });
    assert.ok(String(result.content[0].text).includes("exceeds 65536 bytes"));
    const sendQuery = fakeClient.queries.find((q) =>
      q.sql.trim().toLowerCase().startsWith("select send_agent_message"),
    );
    assert.ok(!sendQuery, "oversized text must not reach the database");
  });
});

describe("B06: agent_chat_send rejects empty text at schema layer", () => {
  it("fails TypeBox validation before execute body runs", () => {
    assert.ok(!Value.Check(SendParams, { to: "nova", text: "" }));
  });
});

describe("B07: agent_chat_send rejects replyTo: 0", () => {
  it("fails TypeBox minimum: 1 validation", () => {
    assert.ok(!Value.Check(SendParams, { to: "nova", text: "hello", replyTo: 0 }));
  });
});

describe("B08: agent_chat_send rejects replyTo: -1", () => {
  it("fails TypeBox minimum: 1 validation", () => {
    assert.ok(!Value.Check(SendParams, { to: "nova", text: "hello", replyTo: -1 }));
  });
});

describe("B09: agent_chat_send rejects non-integer replyTo", () => {
  it("fails TypeBox Type.Integer validation", () => {
    assert.ok(!Value.Check(SendParams, { to: "nova", text: "hello", replyTo: 3.5 }));
  });
});

describe("B10: agent_chat_send rejects replyTo above int32 max", () => {
  it("fails TypeBox maximum validation", () => {
    assert.ok(!Value.Check(SendParams, { to: "nova", text: "hello", replyTo: 2147483648 }));
  });
});

describe("B11: agent_chat_send rejects unknown additional properties", () => {
  it("fails additionalProperties: false validation", () => {
    assert.ok(!Value.Check(SendParams, { to: "nova", text: "hello", extra: "z" }));
  });
});

describe("B12: agent_chat_mark rejects duplicate ids", () => {
  it("fails TypeBox uniqueItems validation", () => {
    assert.ok(!Value.Check(MarkParams, { ids: [5, 5], status: "handled" }));
  });
});

describe("B13: agent_chat_mark restricts status to handled/skipped at tool layer", () => {
  it("rejects responded even though DB function accepts it", () => {
    assert.ok(!Value.Check(MarkParams, { ids: [1], status: "responded" }));
  });
});

describe("B14: agent_chat_mark rejects empty ids array", () => {
  it("fails TypeBox minItems validation", () => {
    assert.ok(!Value.Check(MarkParams, { ids: [], status: "handled" }));
  });
});

describe("B15: agent_chat_send rejects empty to string", () => {
  it("fails TypeBox minLength validation", () => {
    assert.ok(!Value.Check(SendParams, { to: "", text: "hello" }));
  });
});
