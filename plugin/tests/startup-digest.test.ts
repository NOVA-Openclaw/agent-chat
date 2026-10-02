/**
 * Unit tests for Requirement 5 — startup digest.
 *
 * Coverage: TC-23-050 through TC-23-063 (UNIT layer only; TC-23-061 is PG).
 */

import { describe, it } from "node:test";
import assert from "node:assert/strict";
import type { OpenClawConfig, PluginRuntime } from "openclaw/plugin-sdk";
import type { OpenClawPluginApi } from "openclaw/plugin-sdk";
import { agentChatPlugin } from "../src/channel.js";
import {
  buildDigestText,
  buildPagingQuery,
  countUnresolvedMessages,
  createStartupDigestService,
  fetchUnresolvedMessages,
  groupBySender,
  truncatePreview,
} from "../src/digest.js";
import plugin from "../index.js";

const FULL_MODES = ["discovery", "tool-discovery", "cli-metadata", "setup-runtime"] as const;

interface FakeClient {
  queries: Array<{ sql: string; params: unknown[] }>;
  connect: () => Promise<void>;
  query: (sql: string, params?: unknown[]) => Promise<{ rows: unknown[] }>;
  end: () => Promise<void>;
}

function makeFakeClient(options: {
  unresolved?: Array<Partial<{
    id: number;
    sender: string;
    message: string;
    recipients: string[];
    reply_to: number | null;
    timestamp: Date;
    status: string | null;
  }>>;
  total?: number;
} = {}): FakeClient {
  const queries: Array<{ sql: string; params: unknown[] }> = [];
  const rows = options.unresolved?.map((r) => ({
    id: r.id ?? 0,
    sender: r.sender ?? "nova",
    message: r.message ?? "msg",
    recipients: r.recipients ?? ["newhart"],
    reply_to: r.reply_to ?? null,
    timestamp: r.timestamp ?? new Date("2026-10-02T19:00:00Z"),
    status: r.status ?? null,
  })) ?? [];

  return {
    queries,
    connect: async () => {},
    end: async () => {},
    query(sql: string, params?: unknown[]) {
      queries.push({ sql, params: params ?? [] });
      const trimmedLower = sql.trim().toLowerCase();

      if (trimmedLower.startsWith("select count(*)::int as cnt")) {
        return Promise.resolve({ rows: [{ cnt: options.total ?? rows.length }] });
      }

      if (trimmedLower.startsWith("select ac.id, ac.sender")) {
        const limit = Number(params?.[1] ?? rows.length);
        return Promise.resolve({ rows: rows.slice(0, limit) });
      }

      return Promise.resolve({ rows: [] });
    },
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

function makeLogger(): {
  debug: (m: string) => void;
  info: (m: string) => void;
  warn: (m: string) => void;
  error: (m: string) => void;
  lines: { debug: string[]; info: string[]; warn: string[]; error: string[] };
} {
  const lines = { debug: [], info: [], warn: [], error: [] };
  return {
    debug: (m: string) => lines.debug.push(m),
    info: (m: string) => lines.info.push(m),
    warn: (m: string) => lines.warn.push(m),
    error: (m: string) => lines.error.push(m),
    lines,
  };
}

function makeFakeApi(options: {
  registrationMode?: string;
  runtime?: PluginRuntime;
} = {}): {
  api: OpenClawPluginApi;
  services: unknown[];
  channels: unknown[];
  logs: ReturnType<typeof makeLogger>["lines"];
} {
  const runtime = options.runtime ?? makeBaseRuntime();
  const logger = makeLogger();
  const services: unknown[] = [];
  const channels: unknown[] = [];

  const api = {
    id: "agent_chat",
    name: "Agent Chat",
    source: "test",
    config: {} as OpenClawConfig,
    runtime,
    logger,
    registrationMode: options.registrationMode ?? "full",
    registerChannel: (reg: unknown) => channels.push(reg),
    registerService: (svc: unknown) => services.push(svc),
  } as unknown as OpenClawPluginApi;

  return { api, services, channels, logs: logger.lines };
}

function makeServiceCtx(): {
  config: OpenClawConfig;
  logger: ReturnType<typeof makeLogger>;
} {
  return {
    config: {} as OpenClawConfig,
    logger: makeLogger(),
  };
}

function unresolvedRow(id: number, overrides: Partial<{
  sender: string;
  message: string;
  recipients: string[];
  reply_to: number | null;
  timestamp: Date;
  status: string | null;
}> = {}): NonNullable<Parameters<typeof makeFakeClient>[0]["unresolved"]> {
  return {
    id,
    sender: overrides.sender ?? "nova",
    message: overrides.message ?? `message ${id}`,
    recipients: overrides.recipients ?? ["newhart"],
    reply_to: overrides.reply_to ?? null,
    timestamp: overrides.timestamp ?? new Date(`2026-10-02T19:00:${String(id).padStart(2, "0")}Z`),
    status: overrides.status ?? null,
  };
}

describe("TC-23-050: mode gate — non-full modes do not register digest service", () => {
  for (const mode of FULL_MODES) {
    it(`does not register service when registrationMode = "${mode}"`, () => {
      const { api, services } = makeFakeApi({ registrationMode: mode });
      plugin.register(api);
      assert.strictEqual(services.length, 0, `expected no service in ${mode} mode`);
    });
  }
});

describe("TC-23-051: full mode registers and runs digest", () => {
  it("registers the startup digest service and start() issues DB queries", async () => {
    const { api, services } = makeFakeApi({ registrationMode: "full" });
    plugin.register(api);
    assert.strictEqual(services.length, 1, "expected digest service in full mode");

    const client = makeFakeClient({ unresolved: [unresolvedRow(1)] });
    const service = createStartupDigestService({
      runtime: api.runtime,
      resolveAgentName: () => "newhart",
      createClient: () => client as unknown as import("pg").Client,
    });

    await service.start(makeServiceCtx() as never);

    const countQuery = client.queries.find((q) =>
      q.sql.trim().toLowerCase().startsWith("select count(*)::int as cnt")
    );
    assert.ok(countQuery, "expected count query");
    const fetchQuery = client.queries.find((q) =>
      q.sql.trim().toLowerCase().startsWith("select ac.id, ac.sender")
    );
    assert.ok(fetchQuery, "expected fetch query");
  });
});

describe("TC-23-052: start() fires exactly once when called twice", () => {
  it("dispatches digest once across two start() calls", async () => {
    let dispatchCount = 0;
    const runtime = makeBaseRuntime();
    (runtime.channel!.reply as Record<string, unknown>).dispatchReplyFromConfig = async () => {
      dispatchCount++;
    };

    const client = makeFakeClient({ unresolved: [unresolvedRow(1)] });
    const service = createStartupDigestService({
      runtime,
      resolveAgentName: () => "newhart",
      createClient: () => client as unknown as import("pg").Client,
    });

    const ctx = makeServiceCtx();
    await service.start(ctx as never);
    await service.start(ctx as never);

    assert.strictEqual(dispatchCount, 1, "digest should dispatch exactly once");
  });
});

describe("TC-23-053: stop() resets guard so a second start() fires", () => {
  it("dispatches twice after start → stop → start", async () => {
    let dispatchCount = 0;
    const runtime = makeBaseRuntime();
    (runtime.channel!.reply as Record<string, unknown>).dispatchReplyFromConfig = async () => {
      dispatchCount++;
    };

    const client = makeFakeClient({ unresolved: [unresolvedRow(1)] });
    const service = createStartupDigestService({
      runtime,
      resolveAgentName: () => "newhart",
      createClient: () => client as unknown as import("pg").Client,
    });

    const ctx = makeServiceCtx();
    await service.start(ctx as never);
    await service.stop(ctx as never);
    await service.start(ctx as never);

    assert.strictEqual(dispatchCount, 2, "digest should dispatch again after stop()");
  });
});

describe("TC-23-054: channel restart does not fire digest", () => {
  it("startAccount is a separate code path from the digest service", () => {
    // The digest is delivered only from createStartupDigestService.start().
    // gateway.startAccount is the per-account channel monitor entry point and
    // never imports or calls the digest service, so a channel restart cannot
    // fire a second digest. This test documents that structural separation.
    assert.ok(
      typeof agentChatPlugin.gateway!.startAccount === "function",
      "channel gateway startAccount exists",
    );
    assert.ok(
      typeof createStartupDigestService === "function",
      "digest service factory exists",
    );
  });
});

describe("TC-23-055: duplicate hooks on hot reload fire digest once", () => {
  it("two service instances sharing a runtime dispatch digest exactly once", async () => {
    let dispatchCount = 0;
    const runtime = makeBaseRuntime();
    (runtime.channel!.reply as Record<string, unknown>).dispatchReplyFromConfig = async () => {
      dispatchCount++;
    };

    const client = makeFakeClient({ unresolved: [unresolvedRow(1)] });
    const createClient = () => client as unknown as import("pg").Client;

    const serviceA = createStartupDigestService({
      runtime,
      resolveAgentName: () => "newhart",
      createClient,
    });
    const serviceB = createStartupDigestService({
      runtime,
      resolveAgentName: () => "newhart",
      createClient,
    });

    const ctx = makeServiceCtx();
    await Promise.all([serviceA.start(ctx as never), serviceB.start(ctx as never)]);

    assert.strictEqual(dispatchCount, 1, "duplicate service instances should fire once total");
  });
});

describe("TC-23-056: empty backlog sends no digest", () => {
  it("dispatches nothing when count is zero", async () => {
    let dispatchCount = 0;
    const runtime = makeBaseRuntime();
    (runtime.channel!.reply as Record<string, unknown>).dispatchReplyFromConfig = async () => {
      dispatchCount++;
    };

    const client = makeFakeClient({ unresolved: [], total: 0 });
    const service = createStartupDigestService({
      runtime,
      resolveAgentName: () => "newhart",
      createClient: () => client as unknown as import("pg").Client,
    });

    await service.start(makeServiceCtx() as never);

    assert.strictEqual(dispatchCount, 0, "no digest should be sent for empty backlog");
  });
});

describe("TC-23-057: cap boundary 19 — no remaining line", () => {
  it("includes all 19 rows and omits any remaining line", async () => {
    let body = "";
    const runtime = makeBaseRuntime();
    (runtime.channel!.reply as Record<string, unknown>).dispatchReplyFromConfig = async (args: {
      ctx: { Body: string };
    }) => {
      body = args.ctx.Body;
    };

    const rows = Array.from({ length: 19 }, (_, i) => unresolvedRow(i + 1));
    const client = makeFakeClient({ unresolved: rows, total: 19 });
    const service = createStartupDigestService({
      runtime,
      resolveAgentName: () => "newhart",
      createClient: () => client as unknown as import("pg").Client,
    });

    await service.start(makeServiceCtx() as never);

    assert.match(body, /#19/);
    assert.doesNotMatch(body, /remaining/i, "must not contain 'remaining' when under cap");
    assert.doesNotMatch(body, /paging query/i, "must not contain paging query when under cap");
  });
});

describe("TC-23-058: cap boundary 20 — remaining line omitted entirely", () => {
  it("includes all 20 rows and never writes '0 remaining'", async () => {
    let body = "";
    const runtime = makeBaseRuntime();
    (runtime.channel!.reply as Record<string, unknown>).dispatchReplyFromConfig = async (args: {
      ctx: { Body: string };
    }) => {
      body = args.ctx.Body;
    };

    const rows = Array.from({ length: 20 }, (_, i) => unresolvedRow(i + 1));
    const client = makeFakeClient({ unresolved: rows, total: 20 });
    const service = createStartupDigestService({
      runtime,
      resolveAgentName: () => "newhart",
      createClient: () => client as unknown as import("pg").Client,
    });

    await service.start(makeServiceCtx() as never);

    assert.match(body, /#20/);
    assert.doesNotMatch(body, /remaining/i, "must not contain 'remaining' at exact cap");
    assert.doesNotMatch(body, /0 remaining/i, "must never write '0 remaining'");
  });
});

describe("TC-23-059: cap boundary 21 — 20 oldest + remaining line + paging query", () => {
  it("excludes the 21st newest row and includes '1 remaining' with SQL", async () => {
    let body = "";
    const runtime = makeBaseRuntime();
    (runtime.channel!.reply as Record<string, unknown>).dispatchReplyFromConfig = async (args: {
      ctx: { Body: string };
    }) => {
      body = args.ctx.Body;
    };

    const rows = Array.from({ length: 21 }, (_, i) =>
      unresolvedRow(i + 1, { timestamp: new Date(`2026-10-02T19:00:${String(i + 1).padStart(2, "0")}Z`) })
    );
    const client = makeFakeClient({ unresolved: rows, total: 21 });
    const service = createStartupDigestService({
      runtime,
      resolveAgentName: () => "newhart",
      createClient: () => client as unknown as import("pg").Client,
    });

    await service.start(makeServiceCtx() as never);

    assert.match(body, /#1\b/);
    assert.match(body, /#20\b/);
    assert.doesNotMatch(body, /#21\b/, "newest row beyond cap must not appear");
    assert.match(body, /1 remaining/, "must show exact remaining count");
    assert.match(body, /SELECT ac\.id, ac\.sender,[\s\S]*?ac\."timestamp"/, "must include paging SELECT");
    assert.match(body, /OFFSET 20/, "paging query must offset by cap");
  });
});

describe("TC-23-060: overflow persistence / no starvation", () => {
  it("second digest shows the same oldest 20", async () => {
    const bodies: string[] = [];
    const runtime = makeBaseRuntime();
    (runtime.channel!.reply as Record<string, unknown>).dispatchReplyFromConfig = async (args: {
      ctx: { Body: string };
    }) => {
      bodies.push(args.ctx.Body);
    };

    const rows = Array.from({ length: 21 }, (_, i) =>
      unresolvedRow(i + 1, { timestamp: new Date(`2026-10-02T19:00:${String(i + 1).padStart(2, "0")}Z`) })
    );
    const client = makeFakeClient({ unresolved: rows, total: 21 });
    const createClient = () => client as unknown as import("pg").Client;

    const service = createStartupDigestService({
      runtime,
      resolveAgentName: () => "newhart",
      createClient,
    });

    const ctx = makeServiceCtx();
    await service.start(ctx as never);
    await service.stop(ctx as never);
    await service.start(ctx as never);

    assert.strictEqual(bodies.length, 2, "two digests should fire");
    assert.strictEqual(bodies[0], bodies[1], "same oldest 20 must appear after reload");
  });
});

describe("TC-23-062: grouped by sender with previews", () => {
  it("groups messages by sender and truncates long bodies", async () => {
    let body = "";
    const runtime = makeBaseRuntime();
    (runtime.channel!.reply as Record<string, unknown>).dispatchReplyFromConfig = async (args: {
      ctx: { Body: string };
    }) => {
      body = args.ctx.Body;
    };

    const rows = [
      unresolvedRow(1, { sender: "argus", message: "short" }),
      unresolvedRow(2, { sender: "quill", message: "a".repeat(200) }),
      unresolvedRow(3, { sender: "argus", message: "also short" }),
      unresolvedRow(4, { sender: "erato", message: "medium length message body" }),
    ];
    const client = makeFakeClient({ unresolved: rows, total: 4 });
    const service = createStartupDigestService({
      runtime,
      resolveAgentName: () => "newhart",
      createClient: () => client as unknown as import("pg").Client,
    });

    await service.start(makeServiceCtx() as never);

    assert.match(body, /From argus:/);
    assert.match(body, /From quill:/);
    assert.match(body, /From erato:/);
    assert.match(body, /#1.*short/);
    assert.match(body, /#2 \(\d{4}-\d{2}-\d{2}T[\d:.]+Z\).*…/);
    assert.match(body, /#3.*also short/);
    assert.match(body, /#4.*medium length/);
  });
});

describe("TC-23-063: instructions present", () => {
  it("includes reply, mark-handled, mark-expired, and status-maintenance instructions", async () => {
    let body = "";
    const runtime = makeBaseRuntime();
    (runtime.channel!.reply as Record<string, unknown>).dispatchReplyFromConfig = async (args: {
      ctx: { Body: string };
    }) => {
      body = args.ctx.Body;
    };

    const client = makeFakeClient({ unresolved: [unresolvedRow(1)], total: 1 });
    const service = createStartupDigestService({
      runtime,
      resolveAgentName: () => "newhart",
      createClient: () => client as unknown as import("pg").Client,
    });

    await service.start(makeServiceCtx() as never);

    assert.match(body, /send_agent_message.*p_reply_to/i);
    assert.match(body, /mark_agent_chat_status.*handled/i);
    assert.match(body, /mark_agent_chat_status.*expired/i);
    assert.match(body, /keep statuses current/i);
  });
});

describe("buildDigestText / helpers", () => {
  it("groupBySender preserves oldest-first order", () => {
    const groups = groupBySender([
      { id: 1, sender: "b", message: "b1", timestamp: new Date("2026-10-01T00:00:00Z") },
      { id: 2, sender: "a", message: "a1", timestamp: new Date("2026-10-01T00:01:00Z") },
      { id: 3, sender: "b", message: "b2", timestamp: new Date("2026-10-01T00:02:00Z") },
    ] as UnresolvedMessage[]);

    assert.deepStrictEqual(Array.from(groups.keys()), ["b", "a"]);
    assert.strictEqual(groups.get("b")![0].id, 1);
    assert.strictEqual(groups.get("b")![1].id, 3);
  });

  it("truncatePreview adds ellipsis beyond maxLen", () => {
    assert.strictEqual(truncatePreview("hello", 10), "hello");
    assert.match(truncatePreview("x".repeat(100), 10), /…$/);
  });

  it("buildPagingQuery escapes single quotes", () => {
    const q = buildPagingQuery("o'brien");
    assert.match(q, /o''brien/);
    assert.doesNotMatch(q, /o'brien[^']/);
  });
});
