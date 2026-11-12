/**
 * Unit tests for SE#1475 / nova-openclaw#239: agent_chat monitor shutdown.
 *
 * startAgentChatMonitor is a long-lived PluginInstance call. Core gives the
 * plugin 5s to drain before forced retirement, so the monitor must:
 *   - stop accepting new notifications after abort,
 *   - await in-flight notification/keepalive handlers (bounded),
 *   - await client.end(),
 *   - clear timers,
 * before the long-lived promise resolves.
 */

import { describe, it, beforeEach } from "node:test";
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import type { OpenClawConfig, PluginRuntime } from "openclaw/plugin-sdk";
import { setAgentChatRuntime } from "../src/runtime.js";
import { startAgentChatMonitor } from "../src/channel.js";

// Provide a DB user so validateAgentChatConfig() succeeds without a real config file.
process.env.PGUSER = "testagent";

function makeCfg(): OpenClawConfig {
  return {
    agents: { entries: { main: {} } },
  } as unknown as OpenClawConfig;
}

function makeRuntime(): PluginRuntime {
  return {
    channel: {
      reply: {
        resolveEnvelopeFormatOptions: () => ({}),
        formatInboundEnvelope(input: { body: string }) {
          return input.body;
        },
        formatAgentEnvelope(input: { body: string }) {
          return input.body;
        },
        finalizeInboundContext(ctx: Record<string, unknown>) {
          return ctx;
        },
        createReplyDispatcherWithTyping() {
          return {
            dispatcher: {
              waitForIdle: async () => {},
              markComplete: () => {},
            },
            replyOptions: {},
            markDispatchIdle: () => {},
          };
        },
        dispatchReplyFromConfig: async () => {},
        withReplyDispatcher: async ({ run }: { run: () => Promise<unknown> }) => run(),
      },
    },
  } as unknown as PluginRuntime;
}

interface FakeNotification {
  channel: string;
  payload?: string;
}

class FakeClient extends EventEmitter {
  queries: string[] = [];
  ended = false;
  destroyed = false;
  endDelay = 30;
  private endHangs = false;
  private blockAll = false;
  private deferred?: {
    resolve(value: unknown): void;
    reject(reason: unknown): void;
    sql: string;
  };

  // Expose a connection stream so forceCloseClient() can destroy it.
  connection = {
    stream: {
      destroy: () => {
        this.destroyed = true;
        this.ended = true;
      },
    },
  };

  connect() {
    return Promise.resolve();
  }

  async end() {
    if (this.endHangs) {
      return new Promise<void>(() => {});
    }
    await new Promise((resolve) => setTimeout(resolve, this.endDelay));
    this.ended = true;
  }

  query(sql: string, _params?: unknown[]) {
    this.queries.push(sql);
    if (
      this.blockAll &&
      !/^UNLISTEN/i.test(sql) &&
      sql.trim() !== "SELECT 1"
    ) {
      return new Promise((resolve, reject) => {
        this.deferred = { resolve, reject, sql };
      });
    }

    const t = sql.trim().toLowerCase();
    if (t.startsWith("listen ")) {
      return Promise.resolve();
    }
    if (t.startsWith("select agent_chat_pending_alerts")) {
      return Promise.resolve({ rows: [] });
    }
    if (t.startsWith("select ac.id")) {
      return Promise.resolve({ rows: [] });
    }
    if (t.startsWith("select agent_chat_is_muted")) {
      return Promise.resolve({ rows: [{ muted: false }] });
    }
    if (
      t.startsWith("insert into public.agent_chat_processed") ||
      t.startsWith("insert into agent_chat_processed")
    ) {
      return Promise.resolve({
        rows: [{ chat_id: 1, agent: "testagent", status: "received" }],
      });
    }
    if (t.startsWith("update agent_chat_processed")) {
      return Promise.resolve({ rows: [] });
    }
    if (t.startsWith("select agent_chat_mark_alerts_seen")) {
      return Promise.resolve({ rows: [] });
    }
    return Promise.resolve({ rows: [] });
  }

  block() {
    this.blockAll = true;
  }

  unblock() {
    const d = this.deferred;
    if (d) {
      d.resolve({ rows: [] });
      this.deferred = undefined;
    }
  }

  hangEnd() {
    this.endHangs = true;
  }
}

function makeCtx(signal: AbortSignal) {
  return {
    account: {
      accountId: "default",
      name: "Default",
      enabled: true,
      config: { pollIntervalMs: 10 },
    },
    cfg: makeCfg(),
    log: { info: () => {}, error: () => {}, debug: () => {} },
    abortSignal: signal,
  } as unknown as Parameters<typeof startAgentChatMonitor>[0];
}

async function wait(ms: number) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

describe("SE#1475: startAgentChatMonitor shutdown", () => {
  beforeEach(() => {
    setAgentChatRuntime(makeRuntime());
  });

  it("resolves only after client.end() has finished", async () => {
    const client = new FakeClient();
    const controller = new AbortController();
    const promise = startAgentChatMonitor(makeCtx(controller.signal), client as any);

    await wait(15);
    controller.abort();
    await promise;

    assert.strictEqual(
      client.ended,
      true,
      "monitor promise must not resolve until client.end() has completed",
    );
  });

  it("awaits an in-flight notification handler before resolving", async () => {
    const client = new FakeClient();
    const controller = new AbortController();
    const promise = startAgentChatMonitor(makeCtx(controller.signal), client as any);

    await wait(15);
    client.block();
    client.emit("notification", {
      channel: "agent_chat_breaker_alert",
    } as FakeNotification);
    await wait(10);

    assert.ok(
      client.queries.some((q) => /agent_chat_pending_alerts/i.test(q)),
      "handler should have issued the pending-alerts query",
    );

    controller.abort();
    await wait(15);

    assert.strictEqual(
      client.ended,
      false,
      "client must not be closed while a handler is still in flight",
    );

    client.unblock();
    await promise;

    assert.strictEqual(
      client.ended,
      true,
      "client must be closed after the in-flight handler settles",
    );
  });

  it("ignores notifications that arrive after abort", async () => {
    const client = new FakeClient();
    const controller = new AbortController();
    const promise = startAgentChatMonitor(makeCtx(controller.signal), client as any);

    await wait(15);
    const queryCountBeforeAbort = client.queries.filter((q) =>
      /agent_chat_pending_alerts/i.test(q),
    ).length;

    controller.abort();
    await wait(15);

    client.emit("notification", { channel: "agent_chat" } as FakeNotification);
    await wait(25);

    const queryCountAfterAbort = client.queries.filter((q) =>
      /agent_chat_pending_alerts/i.test(q),
    ).length;

    assert.strictEqual(
      queryCountAfterAbort,
      queryCountBeforeAbort,
      "no new notification work should start after abort",
    );

    await promise;
  });

  it("stops the keepalive interval on abort", async () => {
    const client = new FakeClient();
    const controller = new AbortController();
    const promise = startAgentChatMonitor(makeCtx(controller.signal), client as any);

    await wait(40);
    const keepAlivesBeforeAbort = client.queries.filter((q) => q.trim() === "SELECT 1").length;
    assert.ok(keepAlivesBeforeAbort >= 1, "keepalive should have fired before abort");

    controller.abort();
    await wait(40);

    const keepAlivesAfterAbort = client.queries.filter((q) => q.trim() === "SELECT 1").length;

    assert.strictEqual(
      keepAlivesAfterAbort,
      keepAlivesBeforeAbort,
      "keepalive interval must be cleared after abort",
    );

    await promise;
  });

  it("resolves within 4s when a notification handler never settles", async () => {
    const client = new FakeClient();
    const controller = new AbortController();
    const promise = startAgentChatMonitor(makeCtx(controller.signal), client as any);

    await wait(15);
    client.block();
    client.emit("notification", { channel: "agent_chat" } as FakeNotification);
    await wait(10);

    assert.ok(
      client.queries.some((q) => /agent_chat_pending_alerts/i.test(q)),
      "handler should have started before abort",
    );

    const start = Date.now();
    controller.abort();
    await promise;
    const elapsed = Date.now() - start;

    assert.ok(
      elapsed < 4000,
      `monitor should resolve within 4s of abort, took ${elapsed}ms`,
    );
    assert.strictEqual(
      client.ended,
      true,
      "client must be closed after shutdown timeout",
    );
  });

  it("resolves within 4s and destroys the connection when client.end() hangs", async () => {
    const client = new FakeClient();
    client.hangEnd();
    const controller = new AbortController();
    const promise = startAgentChatMonitor(makeCtx(controller.signal), client as any);

    await wait(15);

    const start = Date.now();
    controller.abort();
    await promise;
    const elapsed = Date.now() - start;

    assert.ok(
      elapsed < 4000,
      `monitor should resolve within 4s of abort, took ${elapsed}ms`,
    );
    assert.strictEqual(
      client.destroyed,
      true,
      "connection stream must be destroyed when client.end() hangs",
    );
  });
});
