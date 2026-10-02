/**
 * Unit tests for Requirements 1: gateway-build compatibility and feature
 * detection for formatInboundEnvelope and deprecated reply functions.
 *
 * TC-23-001 through TC-23-007
 */

import { describe, it, before, after } from "node:test";
import assert from "node:assert/strict";
import type { PluginRuntime, OpenClawConfig } from "openclaw/plugin-sdk";
import {
  formatAgentChatEnvelope,
  checkDeprecatedReplyFunctions,
  processAgentChatMessage,
  type AgentChatEnvelopeInput,
} from "../src/channel.js";
import { setAgentChatRuntime } from "../src/runtime.js";

const SAMPLE_MESSAGE = {
  id: 42,
  sender: "nova",
  message: "hello world",
  recipients: ["newhart"],
  reply_to: null,
  timestamp: new Date("2026-10-02T19:00:00Z"),
};

function makeEnvelopeOptions(_cfg: OpenClawConfig): unknown {
  return { prefix: "", suffix: "" };
}

function makeOldRuntime(): PluginRuntime {
  return {
    channel: {
      reply: {
        resolveEnvelopeFormatOptions: makeEnvelopeOptions,
        formatInboundEnvelope(input: AgentChatEnvelopeInput) {
          return `${input.from}: ${input.body}`;
        },
        formatAgentEnvelope(input: AgentChatEnvelopeInput) {
          // Should never be called when formatInboundEnvelope is present;
          // if it is, make it obvious in test output.
          return `UNEXPECTED_SHIM ${input.from}: ${input.body}`;
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

function makeNewRuntime(): PluginRuntime {
  return {
    channel: {
      reply: {
        resolveEnvelopeFormatOptions: makeEnvelopeOptions,
        formatAgentEnvelope(input: AgentChatEnvelopeInput) {
          // formatAgentEnvelope applies envelope formatting; in this mock the
          // envelope options are a no-op, so it returns the body unchanged.
          // The shim pre-pends the sender, so the final output matches OLD.
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

function makeMissingDeprecatedRuntime(
  missing: Array<"finalizeInboundContext" | "createReplyDispatcherWithTyping" | "dispatchReplyFromConfig">,
): PluginRuntime {
  const rt = makeNewRuntime();
  for (const key of missing) {
    delete (rt.channel!.reply as Record<string, unknown>)[key];
  }
  return rt;
}

function makeMalformedRuntime(
  formatInboundEnvelopeValue: unknown,
): PluginRuntime {
  // Use NEW build shape as base so the fallback formatAgentEnvelope returns the
  // body unchanged and the shim output matches the OLD-build expectation.
  const rt = makeNewRuntime();
  (rt.channel!.reply as Record<string, unknown>).formatInboundEnvelope = formatInboundEnvelopeValue;
  return rt;
}

function makeMissingBothEnvelopesRuntime(): PluginRuntime {
  const rt = makeNewRuntime();
  delete (rt.channel!.reply as Record<string, unknown>).formatAgentEnvelope;
  return rt;
}

function makeFakeClient(): {
  queries: Array<{ sql: string; params: unknown[] }>;
  query: (sql: string, params?: unknown[]) => Promise<{ rows: unknown[] }>;
} {
  const queries: Array<{ sql: string; params: unknown[] }> = [];
  return {
    queries,
    query(sql: string, params?: unknown[]) {
      queries.push({ sql, params: params ?? [] });
      if (sql.toLowerCase().startsWith("update agent_chat_processed")) {
        return Promise.resolve({ rows: [] });
      }
      if (sql.toLowerCase().startsWith("insert into agent_chat_processed")) {
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

describe("TC-23-001: OLD build uses formatInboundEnvelope directly", () => {
  it("returns the direct-formatted body and never calls the shim", () => {
    const runtime = makeOldRuntime();
    let shimCalled = false;
    (runtime.channel!.reply as Record<string, unknown>).formatAgentEnvelope = (
      input: AgentChatEnvelopeInput,
    ) => {
      shimCalled = true;
      return `SHIM ${input.from}: ${input.body}`;
    };

    const result = formatAgentChatEnvelope(runtime, {}, {
      sender: "nova",
      message: "hello",
      timestamp: new Date("2026-10-02T19:00:00Z"),
    });

    assert.strictEqual(result.ok, true);
    assert.strictEqual((result as { ok: true; body: string }).body, "nova: hello");
    assert.strictEqual(shimCalled, false);
  });
});

describe("TC-23-001b: OLD build does not call formatAgentEnvelope", () => {
  it("shim path is never invoked when formatInboundEnvelope exists", () => {
    const runtime = makeOldRuntime();
    const result = formatAgentChatEnvelope(runtime, {}, { sender: "nova", message: "hello" });
    assert.strictEqual(result.ok, true);
    const body = (result as { ok: true; body: string }).body;
    assert.doesNotMatch(body, /^UNEXPECTED_SHIM /);
  });
});

describe("TC-23-002: NEW build falls back to formatAgentEnvelope shim", () => {
  it("produces output identical to OLD build for direct chat", () => {
    const runtime = makeNewRuntime();
    const result = formatAgentChatEnvelope(runtime, {}, {
      sender: "nova",
      message: "hello",
      timestamp: new Date("2026-10-02T19:00:00Z"),
    });

    assert.strictEqual(result.ok, true);
    assert.strictEqual((result as { ok: true; body: string }).body, "nova: hello");
  });
});

describe("TC-23-003: shim matches OLD-build golden output for representative inputs", () => {
  const fixtures = [
    { sender: "nova", message: "short", label: "short message" },
    { sender: "nova", message: "line1\nline2\nline3", label: "message with newlines" },
    { sender: "", message: "empty sender", label: "empty-string sender edge" },
    { sender: "nova", message: "🚀 unicode ✓", label: "unicode/emoji body" },
    { sender: "nova", message: "x".repeat(3900), label: "very long body near chunk limit" },
  ];

  for (const fixture of fixtures) {
    it(`matches OLD-build output: ${fixture.label}`, () => {
      const oldRuntime = makeOldRuntime();
      const newRuntime = makeNewRuntime();

      const oldResult = formatAgentChatEnvelope(oldRuntime, {}, {
        sender: fixture.sender,
        message: fixture.message,
        timestamp: new Date("2026-10-02T19:00:00Z"),
      });
      const newResult = formatAgentChatEnvelope(newRuntime, {}, {
        sender: fixture.sender,
        message: fixture.message,
        timestamp: new Date("2026-10-02T19:00:00Z"),
      });

      assert.strictEqual(oldResult.ok, true);
      assert.strictEqual(newResult.ok, true);
      assert.strictEqual(
        (oldResult as { ok: true; body: string }).body,
        (newResult as { ok: true; body: string }).body,
      );
    });
  }
});

describe("TC-23-004: malformed formatInboundEnvelope is treated as absent", () => {
  const malformedValues = [null, "true", {}];

  for (const value of malformedValues) {
    it(`falls back when formatInboundEnvelope is ${JSON.stringify(value)}`, () => {
      const runtime = makeMalformedRuntime(value);
      const result = formatAgentChatEnvelope(runtime, {}, {
        sender: "nova",
        message: "hello",
      });

      assert.strictEqual(result.ok, true);
      assert.strictEqual((result as { ok: true; body: string }).body, "nova: hello");
    });
  }
});

describe("TC-23-005: missing both envelope functions marks failed", () => {
  it("returns an actionable error instead of throwing TypeError", () => {
    const runtime = makeMissingBothEnvelopesRuntime();
    const result = formatAgentChatEnvelope(runtime, {}, {
      sender: "nova",
      message: "hello",
    });

    assert.strictEqual(result.ok, false);
    const error = (result as { ok: false; error: string }).error;
    assert.match(error, /Neither formatInboundEnvelope nor formatAgentEnvelope/);
  });

  it("processAgentChatMessage marks message failed without throwing", async () => {
    const runtime = makeMissingBothEnvelopesRuntime();
    setAgentChatRuntime(runtime);
    const fakeClient = makeFakeClient();
    const fakeCtx = makeFakeCtx();

    await assert.doesNotReject(async () => {
      await processAgentChatMessage({
        message: SAMPLE_MESSAGE,
        client: fakeClient as unknown as import("pg").Client,
        agentName: "newhart",
        cfg: fakeCtx.cfg,
        ctx: fakeCtx as unknown as Parameters<typeof processAgentChatMessage>[0]["ctx"],
      });
    });

    const failedUpdate = fakeClient.queries.find(
      (q) =>
        q.sql.trim().toLowerCase().startsWith("update agent_chat_processed") &&
        q.sql.toLowerCase().includes("set status = 'failed'") &&
        q.params[0] === SAMPLE_MESSAGE.id,
    );
    assert.ok(failedUpdate, "expected a failed status update");
    assert.match(String(failedUpdate.params[2]), /formatInboundEnvelope|formatAgentEnvelope/);
  });
});

describe("TC-23-006: deprecated functions present are used normally", () => {
  it("checkDeprecatedReplyFunctions reports ok for OLD-build shape", () => {
    const result = checkDeprecatedReplyFunctions(makeOldRuntime());
    assert.strictEqual(result.ok, true);
  });

  it("processAgentChatMessage routes message when all functions present", async () => {
    const runtime = makeOldRuntime();
    let dispatchCalled = false;
    (runtime.channel!.reply as Record<string, unknown>).dispatchReplyFromConfig = async () => {
      dispatchCalled = true;
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

    assert.strictEqual(dispatchCalled, true);
    const routedUpdate = fakeClient.queries.find(
      (q) =>
        q.sql.trim().toLowerCase().startsWith("update agent_chat_processed") &&
        q.sql.toLowerCase().includes("set status = 'routed'") &&
        q.params[0] === SAMPLE_MESSAGE.id,
    );
    assert.ok(routedUpdate, "expected a routed status update");
  });
});

describe("TC-23-007: missing dispatchReplyFromConfig marks failed", () => {
  it("checkDeprecatedReplyFunctions reports the missing function", () => {
    const runtime = makeMissingDeprecatedRuntime(["dispatchReplyFromConfig"]);
    const result = checkDeprecatedReplyFunctions(runtime);
    assert.strictEqual(result.ok, false);
    assert.deepStrictEqual((result as { ok: false; missing: string[] }).missing, [
      "dispatchReplyFromConfig",
    ]);
  });

  it("processAgentChatMessage marks failed without throwing", async () => {
    const runtime = makeMissingDeprecatedRuntime(["dispatchReplyFromConfig"]);
    setAgentChatRuntime(runtime);

    const fakeClient = makeFakeClient();
    const fakeCtx = makeFakeCtx();

    await assert.doesNotReject(async () => {
      await processAgentChatMessage({
        message: SAMPLE_MESSAGE,
        client: fakeClient as unknown as import("pg").Client,
        agentName: "newhart",
        cfg: fakeCtx.cfg,
        ctx: fakeCtx as unknown as Parameters<typeof processAgentChatMessage>[0]["ctx"],
      });
    });

    const failedUpdate = fakeClient.queries.find(
      (q) =>
        q.sql.trim().toLowerCase().startsWith("update agent_chat_processed") &&
        q.sql.toLowerCase().includes("set status = 'failed'") &&
        q.params[0] === SAMPLE_MESSAGE.id,
    );
    assert.ok(failedUpdate, "expected a failed status update mentioning dispatchReplyFromConfig");
    assert.match(String(failedUpdate.params[2]), /dispatchReplyFromConfig/);
  });
});
