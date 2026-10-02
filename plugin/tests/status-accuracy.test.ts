/**
 * Unit tests for Requirement 4 (accurate statuses) and Requirement 8
 * (duplicate-dispatch race) — TC-23-033 through TC-23-038, TC-23-041,
 * TC-23-112, TC-23-113, TC-23-115.
 */

import { describe, it } from "node:test";
import assert from "node:assert/strict";
import type { PluginRuntime, OpenClawConfig } from "openclaw/plugin-sdk";
import { processAgentChatMessage } from "../src/channel.js";
import { setAgentChatRuntime } from "../src/runtime.js";

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
  hasLinkedReply?: boolean;
} = {}): {
  queries: Array<{ sql: string; params: unknown[] }>;
  query: (sql: string, params?: unknown[]) => Promise<{ rows: unknown[] }>;
  resetClaim: () => void;
} {
  const queries: Array<{ sql: string; params: unknown[] }> = [];
  let claimGiven = options.claimReturns !== false;
  return {
    queries,
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

      if (trimmedLower.startsWith("insert into")) {
        return Promise.resolve({ rows: [] });
      }

      if (trimmedLower.startsWith("select send_agent_message")) {
        return Promise.resolve({ rows: [{ id: 9999 }] });
      }

      if (trimmedLower.startsWith("select 1 from public.agent_chat where reply_to =")) {
        return Promise.resolve({
          rows: options.hasLinkedReply ? [{ "?column?": 1 }] : [],
        });
      }

      if (trimmedLower.startsWith("update agent_chat_processed")) {
        return Promise.resolve({ rows: [] });
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

function findStatusUpdate(
  queries: Array<{ sql: string; params: unknown[] }>,
  status: string,
  chatId: number,
) {
  return queries.find(
    (q) =>
      q.sql.trim().toLowerCase().startsWith("update agent_chat_processed") &&
      q.sql.toLowerCase().includes(`set status = '${status}'`) &&
      q.params[0] === chatId,
  );
}

function findHandledUpdate(queries: Array<{ sql: string; params: unknown[] }>, chatId: number) {
  return queries.find(
    (q) =>
      q.sql.trim().toLowerCase().startsWith("update agent_chat_processed") &&
      q.sql.toLowerCase().includes("set status = 'handled'") &&
      q.params[0] === chatId,
  );
}

function findRespondedUpdate(queries: Array<{ sql: string; params: unknown[] }>, chatId: number) {
  return queries.find(
    (q) =>
      q.sql.trim().toLowerCase().startsWith("update agent_chat_processed") &&
      q.sql.toLowerCase().includes("set status = 'responded'") &&
      q.params[0] === chatId,
  );
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

describe("TC-23-033: deliver fired → responded", () => {
  it("marks message responded when deliver() was invoked", async () => {
    const runtime = makeBaseRuntime();
    (runtime.channel!.reply as Record<string, unknown>).createReplyDispatcherWithTyping =
      ({ deliver }: Record<string, unknown>) => {
        return {
          dispatcher: {
            waitForIdle: async () => {
              // Simulate the runtime invoking deliver() during the turn.
              await (deliver as (payload: { text: string }) => Promise<void>)({ text: "reply" });
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

    assert.ok(findRoutedUpdate(fakeClient.queries, SAMPLE_MESSAGE.id), "expected routed update");
    assert.ok(
      findRespondedUpdate(fakeClient.queries, SAMPLE_MESSAGE.id),
      "expected responded update",
    );
    assert.ok(
      !findHandledUpdate(fakeClient.queries, SAMPLE_MESSAGE.id),
      "did not expect handled update",
    );
  });
});

describe("TC-23-034: no reply → handled (NEW build, undefined deferred)", () => {
  it("marks message handled when deliver never fired and turn is not deferred", async () => {
    const runtime = makeBaseRuntime();
    setAgentChatRuntime(runtime);

    const fakeClient = makeFakeClient({ hasLinkedReply: false });
    const fakeCtx = makeFakeCtx();

    await processAgentChatMessage({
      message: SAMPLE_MESSAGE,
      client: fakeClient as unknown as import("pg").Client,
      agentName: "newhart",
      cfg: fakeCtx.cfg,
      ctx: fakeCtx as unknown as Parameters<typeof processAgentChatMessage>[0]["ctx"],
    });

    assert.ok(findRoutedUpdate(fakeClient.queries, SAMPLE_MESSAGE.id), "expected routed update");
    assert.ok(findHandledUpdate(fakeClient.queries, SAMPLE_MESSAGE.id), "expected handled update");
    assert.ok(
      !findRespondedUpdate(fakeClient.queries, SAMPLE_MESSAGE.id),
      "did not expect responded update",
    );
  });
});

describe("TC-23-035/036: deferred turn stays routed", () => {
  const values: Array<{ value: "steer" | "followup"; label: string }> = [
    { value: "followup", label: "followup" },
    { value: "steer", label: "steer" },
  ];

  for (const { value, label } of values) {
    it(`keeps status routed when deferredToActiveRun = ${label}`, async () => {
      const runtime = makeBaseRuntime();
      (runtime.channel!.reply as Record<string, unknown>).dispatchReplyFromConfig = async () => {
        return { deferredToActiveRun: value };
      };
      setAgentChatRuntime(runtime);

      const fakeClient = makeFakeClient({ hasLinkedReply: false });
      const fakeCtx = makeFakeCtx();

      await processAgentChatMessage({
        message: SAMPLE_MESSAGE,
        client: fakeClient as unknown as import("pg").Client,
        agentName: "newhart",
        cfg: fakeCtx.cfg,
        ctx: fakeCtx as unknown as Parameters<typeof processAgentChatMessage>[0]["ctx"],
      });

      assert.ok(findRoutedUpdate(fakeClient.queries, SAMPLE_MESSAGE.id), "expected routed update");
      assert.ok(
        !findHandledUpdate(fakeClient.queries, SAMPLE_MESSAGE.id),
        "did not expect handled update",
      );
      assert.ok(
        !findRespondedUpdate(fakeClient.queries, SAMPLE_MESSAGE.id),
        "did not expect responded update",
      );
    });
  }
});

describe("TC-23-037: OLD build ambiguous with linked reply → responded", () => {
  it("uses DB-linked reply as tiebreaker and marks responded", async () => {
    const runtime = makeBaseRuntime();
    setAgentChatRuntime(runtime);

    const fakeClient = makeFakeClient({ hasLinkedReply: true });
    const fakeCtx = makeFakeCtx();

    await processAgentChatMessage({
      message: SAMPLE_MESSAGE,
      client: fakeClient as unknown as import("pg").Client,
      agentName: "newhart",
      cfg: fakeCtx.cfg,
      ctx: fakeCtx as unknown as Parameters<typeof processAgentChatMessage>[0]["ctx"],
    });

    assert.ok(findRoutedUpdate(fakeClient.queries, SAMPLE_MESSAGE.id), "expected routed update");
    assert.ok(
      findRespondedUpdate(fakeClient.queries, SAMPLE_MESSAGE.id),
      "expected responded update",
    );
    assert.ok(
      !findHandledUpdate(fakeClient.queries, SAMPLE_MESSAGE.id),
      "did not expect handled update",
    );
  });
});

describe("TC-23-038: OLD build ambiguous without linked reply → handled", () => {
  it("marks handled when no linked reply exists", async () => {
    const runtime = makeBaseRuntime();
    setAgentChatRuntime(runtime);

    const fakeClient = makeFakeClient({ hasLinkedReply: false });
    const fakeCtx = makeFakeCtx();

    await processAgentChatMessage({
      message: SAMPLE_MESSAGE,
      client: fakeClient as unknown as import("pg").Client,
      agentName: "newhart",
      cfg: fakeCtx.cfg,
      ctx: fakeCtx as unknown as Parameters<typeof processAgentChatMessage>[0]["ctx"],
    });

    assert.ok(findRoutedUpdate(fakeClient.queries, SAMPLE_MESSAGE.id), "expected routed update");
    assert.ok(findHandledUpdate(fakeClient.queries, SAMPLE_MESSAGE.id), "expected handled update");
    assert.ok(
      !findRespondedUpdate(fakeClient.queries, SAMPLE_MESSAGE.id),
      "did not expect responded update",
    );
  });
});

describe("TC-23-041: replay regression — already-responded rows are never re-dispatched", () => {
  it("returns early when claim insert returns no row", async () => {
    const runtime = makeBaseRuntime();
    let dispatchCalled = false;
    (runtime.channel!.reply as Record<string, unknown>).dispatchReplyFromConfig = async () => {
      dispatchCalled = true;
    };
    setAgentChatRuntime(runtime);

    const fakeClient = makeFakeClient({ claimReturns: false });
    const fakeCtx = makeFakeCtx();

    await processAgentChatMessage({
      message: SAMPLE_MESSAGE,
      client: fakeClient as unknown as import("pg").Client,
      agentName: "newhart",
      cfg: fakeCtx.cfg,
      ctx: fakeCtx as unknown as Parameters<typeof processAgentChatMessage>[0]["ctx"],
    });

    assert.strictEqual(dispatchCalled, false, "dispatch should not run on a lost claim");
    assert.ok(
      !findRoutedUpdate(fakeClient.queries, SAMPLE_MESSAGE.id),
      "did not expect routed update",
    );
  });
});

describe("TC-23-112: only the claim winner dispatches", () => {
  it("calls dispatchReplyFromConfig exactly once when two workers race", async () => {
    const runtime = makeBaseRuntime();
    let dispatchCount = 0;
    (runtime.channel!.reply as Record<string, unknown>).dispatchReplyFromConfig = async () => {
      dispatchCount++;
    };
    setAgentChatRuntime(runtime);

    let claimSerial = 0;
    const fakeClient = makeFakeClient();
    const originalQuery = fakeClient.query;
    fakeClient.query = async (sql: string, params?: unknown[]) => {
      const trimmedLower = sql.trim().toLowerCase();
      if (
        trimmedLower.startsWith("insert into public.agent_chat_processed") &&
        trimmedLower.includes("returning")
      ) {
        claimSerial++;
        // First caller wins; second caller sees a pre-existing row.
        return Promise.resolve({
          rows: claimSerial === 1
            ? [{ chat_id: params?.[0], agent: params?.[1], status: "received" }]
            : [],
        });
      }
      return originalQuery(sql, params);
    };

    const fakeCtx = makeFakeCtx();

    await Promise.all([
      processAgentChatMessage({
        message: SAMPLE_MESSAGE,
        client: fakeClient as unknown as import("pg").Client,
        agentName: "newhart",
        cfg: fakeCtx.cfg,
        ctx: fakeCtx as unknown as Parameters<typeof processAgentChatMessage>[0]["ctx"],
      }),
      processAgentChatMessage({
        message: SAMPLE_MESSAGE,
        client: fakeClient as unknown as import("pg").Client,
        agentName: "newhart",
        cfg: fakeCtx.cfg,
        ctx: fakeCtx as unknown as Parameters<typeof processAgentChatMessage>[0]["ctx"],
      }),
    ]);

    assert.strictEqual(dispatchCount, 1, "exactly one worker should dispatch");
  });
});

describe("TC-23-113: claimed-then-failed still marks failed", () => {
  it("marks failed when dispatch throws after a successful claim", async () => {
    const runtime = makeBaseRuntime();
    (runtime.channel!.reply as Record<string, unknown>).dispatchReplyFromConfig = async () => {
      throw new Error("dispatch exploded");
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

    const failedUpdate = findFailedUpdate(fakeClient.queries, SAMPLE_MESSAGE.id);
    assert.ok(failedUpdate, "expected failed status update");
    assert.match(String(failedUpdate?.params[2]), /dispatch exploded/);
  });
});

describe("TC-23-115: no duplicate dispatch regardless of implementation mechanism", () => {
  it("observes at most one dispatch for a single message", async () => {
    const runtime = makeBaseRuntime();
    let dispatchCount = 0;
    (runtime.channel!.reply as Record<string, unknown>).dispatchReplyFromConfig = async () => {
      dispatchCount++;
    };
    setAgentChatRuntime(runtime);

    const fakeClient = makeFakeClient();
    const fakeCtx = makeFakeCtx();

    // Simulate many replays/retries against the same message.
    for (let i = 0; i < 5; i++) {
      await processAgentChatMessage({
        message: SAMPLE_MESSAGE,
        client: fakeClient as unknown as import("pg").Client,
        agentName: "newhart",
        cfg: fakeCtx.cfg,
        ctx: fakeCtx as unknown as Parameters<typeof processAgentChatMessage>[0]["ctx"],
      });
    }

    assert.strictEqual(dispatchCount, 1, "message should dispatch at most once");
  });
});
