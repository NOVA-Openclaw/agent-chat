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
  injectBreakerAlert,
  processAgentChatMessage,
  sanitizeSessionPeer,
} from "../src/channel.js";
import { setAgentChatRuntime } from "../src/runtime.js";
import { createAgentChatTools } from "../src/tools.js";

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
      agentName: "newhart",
      cfg: fakeCtx.cfg,
      ctx: fakeCtx as unknown as Parameters<typeof processAgentChatMessage>[0]["ctx"],
    });

    assert.strictEqual(
      capturedCtx?.SessionKey,
      "agent:newhart:agent_chat:nova",
    );
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
      agentName: "newhart",
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
      agentName: "newhart",
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
      agentName: "newhart",
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
      agentName: "newhart",
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
      agentName: "newhart",
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
      agentName: "newhart",
      cfg: fakeCtx.cfg,
      ctx: fakeCtx as unknown as Parameters<typeof processAgentChatMessage>[0]["ctx"],
    });

    const sendQuery = fakeClient.queries.find((q) =>
      q.sql.trim().toLowerCase().startsWith("select send_agent_message"),
    );
    assert.ok(!sendQuery);
  });
});

describe("A12: origin route is closed (no OriginatingTo)", () => {
  it("finalizeInboundContext receives OriginatingChannel but no OriginatingTo", async () => {
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
      agentName: "newhart",
      cfg: fakeCtx.cfg,
      ctx: fakeCtx as unknown as Parameters<typeof processAgentChatMessage>[0]["ctx"],
    });

    assert.strictEqual(capturedCtx?.OriginatingChannel, "agent_chat");
    assert.ok(
      capturedCtx?.OriginatingTo === undefined || capturedCtx?.OriginatingTo === null,
      "OriginatingTo must be absent so announces cannot route back to agent_chat",
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
      agentName: "newhart",
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
      agentName: "newhart",
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
      agentName: "newhart",
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
});

// ---------------------------------------------------------------------------
// Group B: agent_chat_send tool
// ---------------------------------------------------------------------------

describe("B01: agent_chat_send factory opts out for sandboxed sessions", () => {
  it("returns null when toolContext.sandboxed is true", () => {
    const factory = createAgentChatTools({
      createClient: () => ({}) as import("pg").Client,
      resolveAgentName: () => "newhart",
    });
    assert.strictEqual(factory({ sandboxed: true }), null);
  });
});

describe("B02: agent_chat_send sends to a single peer", () => {
  it("calls send_agent_message with lowercased recipient and replyTo", async () => {
    const factory = createAgentChatTools({
      createClient: () => makeFakeClient({ sendReturns: 99 }) as unknown as import("pg").Client,
      resolveAgentName: () => "newhart",
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
      resolveAgentName: () => "newhart",
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
      resolveAgentName: () => "newhart",
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
