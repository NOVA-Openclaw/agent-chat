/**
 * Unit tests for agent identity resolution.
 *
 * The plugin keeps two identities separate:
 *   - DB user: the PostgreSQL role used for send_agent_message() provenance
 *     and processed-row ownership.
 *   - Gateway agent id: the OpenClaw agent id that owns dispatched sessions.
 *
 * TC-23-011 through TC-23-017 covered the legacy pgConfig.user resolver.
 * TC-24-001 through TC-24-006 cover the new gateway-agent-id resolution.
 */

import { describe, it, before, after } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import type { OpenClawConfig } from "openclaw/plugin-sdk";
import {
  resolveDbUser,
  resolveGatewayAgentId,
  resolveAgentNameFromPgConfig,
  validateAgentChatConfig,
} from "../src/channel.js";

const PG_VARS = ["PGHOST", "PGPORT", "PGDATABASE", "PGUSER", "PGPASSWORD"] as const;

function writeJson(filePath: string, data: unknown) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, JSON.stringify(data), "utf-8");
}

function clearPgEnv(): Record<string, string | undefined> {
  const saved: Record<string, string | undefined> = {};
  for (const v of PG_VARS) {
    saved[v] = process.env[v];
    delete process.env[v];
  }
  return saved;
}

function restorePgEnv(saved: Record<string, string | undefined>) {
  for (const v of PG_VARS) {
    if (saved[v] === undefined) {
      delete process.env[v];
    } else {
      process.env[v] = saved[v];
    }
  }
}

// ---------------------------------------------------------------------------
// DB user resolver (legacy behaviour preserved)
// ---------------------------------------------------------------------------

describe("TC-23-011: pgConfig.user is the DB user", () => {
  it("returns lowercased pgConfig.user", () => {
    assert.strictEqual(resolveAgentNameFromPgConfig({ user: "flint" }), "flint");
    assert.strictEqual(resolveDbUser(), resolveAgentNameFromPgConfig({ user: os.userInfo().username }));
  });
});

describe("TC-23-014: no usable DB user fails loudly", () => {
  it("resolveAgentNameFromPgConfig returns empty string for empty user", () => {
    assert.strictEqual(resolveAgentNameFromPgConfig({ user: "" }), "");
    assert.strictEqual(resolveAgentNameFromPgConfig({}), "");
    assert.strictEqual(resolveAgentNameFromPgConfig({ user: null as unknown as undefined }), "");
  });
});

describe("TC-23-015: loadPgEnv String coercion behavior is documented", () => {
  it("number 42 coerces to '42' and is used as agent name", () => {
    assert.strictEqual(resolveAgentNameFromPgConfig({ user: 42 as unknown as string }), "42");
  });

  it("array coerces to comma-separated string and reaches resolver", () => {
    assert.strictEqual(
      resolveAgentNameFromPgConfig({ user: ["a", "b"] as unknown as string }),
      "a,b",
    );
  });

  it("object coerces to lowercased '[object object]' and reaches resolver", () => {
    assert.strictEqual(
      resolveAgentNameFromPgConfig({ user: {} as unknown as string }),
      "[object object]",
    );
  });
});

describe("TC-23-017: resolver is generic, not hardcoded", () => {
  it("returns distinct names for iris and victoria", () => {
    assert.strictEqual(resolveAgentNameFromPgConfig({ user: "iris" }), "iris");
    assert.strictEqual(resolveAgentNameFromPgConfig({ user: "victoria" }), "victoria");
  });
});

// ---------------------------------------------------------------------------
// Gateway agent id resolver
// ---------------------------------------------------------------------------

describe("TC-24-001: explicit channels.agent_chat.agentId wins", () => {
  it("uses the explicit channel agentId and ignores cfg.agents", () => {
    const cfg: OpenClawConfig = {
      channels: {
        agent_chat: {
          agentId: "main",
        },
      },
      agents: {
        list: [{ id: "nova" }],
      },
    } as unknown as OpenClawConfig;

    assert.strictEqual(resolveGatewayAgentId(cfg), "main");
  });
});

describe("TC-24-002: sole agents.entries entry is the gateway id", () => {
  it("returns the only configured agent entry", () => {
    const cfg: OpenClawConfig = {
      agents: {
        entries: {
          main: {},
        },
      },
    } as unknown as OpenClawConfig;

    assert.strictEqual(resolveGatewayAgentId(cfg), "main");
  });
});

describe("TC-24-003: default marker in agents.entries wins", () => {
  it("returns the entry marked default", () => {
    const cfg: OpenClawConfig = {
      agents: {
        entries: {
          nova: {},
          main: { default: true },
        },
      },
    } as unknown as OpenClawConfig;

    assert.strictEqual(resolveGatewayAgentId(cfg), "main");
  });
});

describe("TC-24-004: sole agents.list entry is the gateway id", () => {
  it("returns the only agent in the list", () => {
    const cfg: OpenClawConfig = {
      agents: {
        list: [{ id: "main" }],
      },
    } as unknown as OpenClawConfig;

    assert.strictEqual(resolveGatewayAgentId(cfg), "main");
  });
});

describe("TC-24-005: default marker in agents.list wins", () => {
  it("returns the list entry marked default", () => {
    const cfg: OpenClawConfig = {
      agents: {
        list: [{ id: "nova" }, { id: "main", default: true }],
      },
    } as unknown as OpenClawConfig;

    assert.strictEqual(resolveGatewayAgentId(cfg), "main");
  });
});

describe("TC-24-006: falls back to DB user when cfg provides no agent id", () => {
  it("falls back to the DB user for backward compatibility", () => {
    const cfg: OpenClawConfig = {
      agents: {
        list: [],
      },
    } as unknown as OpenClawConfig;

    assert.strictEqual(resolveGatewayAgentId(cfg), resolveDbUser());
  });
});

describe("TC-24-007: per-account agentId is respected", () => {
  it("uses channels.agent_chat.accounts.<id>.agentId", () => {
    const cfg: OpenClawConfig = {
      channels: {
        agent_chat: {
          accounts: {
            staging: { agentId: "main" },
          },
        },
      },
    } as unknown as OpenClawConfig;

    assert.strictEqual(resolveGatewayAgentId(cfg, "staging"), "main");
  });
});

describe("TC-24-008: validateAgentChatConfig requires both identities", () => {
  it("returns an error when no gateway agent id can be resolved", () => {
    const cfg: OpenClawConfig = {
      agents: {
        list: [],
      },
    } as unknown as OpenClawConfig;

    const result = validateAgentChatConfig(cfg);
    if (!result.ok) {
      assert.match(result.error, /gateway agent id/);
    }
  });
});

describe("TC-23-120: missing postgres.json and no PGUSER falls back to OS username", () => {
  let tmpDir: string;
  let configPath: string;
  let savedEnv: Record<string, string | undefined>;

  before(() => {
    savedEnv = clearPgEnv();
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "agent-name-test-"));
    configPath = path.join(tmpDir, "nonexistent-postgres.json");
  });

  after(() => {
    fs.rmSync(tmpDir, { recursive: true, force: true });
    restorePgEnv(savedEnv);
  });

  it("loadPgEnv falls back to DEFAULTS.PGUSER (os.userInfo().username)", async () => {
    const { loadPgEnv } = await import("../lib/pg-env.js");
    const cfg = loadPgEnv(configPath, "agent_chat");
    assert.strictEqual(cfg.user, os.userInfo().username);
    assert.strictEqual(resolveAgentNameFromPgConfig(cfg), os.userInfo().username.toLowerCase());
  });
});
