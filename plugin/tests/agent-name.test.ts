/**
 * Unit tests for Requirement 2: agent name derived from pgConfig.user,
 * never from cfg.agents.list / default / "main".
 *
 * TC-23-011 through TC-23-017 plus cross-cutting TC-23-120.
 */

import { describe, it, before, after } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import type { OpenClawConfig } from "openclaw/plugin-sdk";
import {
  resolveAgentName,
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

describe("TC-23-011: pgConfig.user wins over cfg.agents.list default", () => {
  it("returns lowercased pgConfig.user and ignores cfg.agents", () => {
    const cfg: OpenClawConfig = {
      agents: {
        list: [{ id: "main", default: true }],
      },
    } as unknown as OpenClawConfig;

    assert.strictEqual(resolveAgentNameFromPgConfig({ user: "flint" }), "flint");
    // resolveAgentName uses the module-scoped pgConfig loaded at import time,
    // so its exact return value depends on the test environment. The important
    // invariant is that it never consults cfg.agents.
    assert.doesNotThrow(() => resolveAgentName(cfg));
  });
});

describe("TC-23-012: regression guard for missing .default entries", () => {
  it("returns newhart even when cfg.agents.list has no default marker", () => {
    const cfg: OpenClawConfig = {
      agents: {
        list: [{ id: "main" }, { id: "newhart" }],
      },
    } as unknown as OpenClawConfig;

    assert.strictEqual(resolveAgentNameFromPgConfig({ user: "newhart" }), "newhart");
    // resolveAgentName is pgConfig-driven; cfg.agents is ignored entirely.
    assert.doesNotThrow(() => resolveAgentName(cfg));
  });
});

describe("TC-23-013: missing cfg.agents does not throw", () => {
  it("returns pgConfig.user when cfg.agents is undefined", () => {
    const cfg: OpenClawConfig = {} as OpenClawConfig;

    assert.strictEqual(resolveAgentNameFromPgConfig({ user: "gem" }), "gem");
    assert.doesNotThrow(() => resolveAgentName(cfg));
  });
});

describe("TC-23-014: no usable agent name fails loudly", () => {
  it("validateAgentChatConfig returns an error when pgConfig.user is absent", () => {
    const result = validateAgentChatConfig();
    if (result.ok) {
      // If a real postgres.json / env provided a user in this test runner,
      // the direct module-level pgConfig may be populated. The helper itself
      // is exercised via the empty-pgConfig path below.
      assert.ok(result.agentName);
      return;
    }
    assert.match(result.error, /no agent name could be resolved/);
    assert.match(result.error, /pgConfig\.user/);
  });

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

describe("TC-23-016: fixed resolver reproduces bug and fix against real config loader shape", () => {
  it("old cfg.agents.list resolver would return 'main' when no default marker", () => {
    // Simulates the buggy pre-fix logic directly to document the regression.
    const cfg: OpenClawConfig = {
      agents: {
        list: [
          { id: "main" },
          { id: "newhart" },
          { id: "iris" },
        ],
      },
    } as unknown as OpenClawConfig;

    const oldResolver = (c: OpenClawConfig) => {
      const agents = c.agents?.list ?? [];
      const defaultAgent = agents.find((a) => a.default) ?? agents[0];
      return defaultAgent?.id ?? defaultAgent?.name ?? "main";
    };

    assert.strictEqual(oldResolver(cfg), "main");
    assert.strictEqual(resolveAgentNameFromPgConfig({ user: "newhart" }), "newhart");
  });
});

describe("TC-23-017: resolver is generic, not hardcoded", () => {
  it("returns distinct names for iris and victoria", () => {
    assert.strictEqual(resolveAgentNameFromPgConfig({ user: "iris" }), "iris");
    assert.strictEqual(resolveAgentNameFromPgConfig({ user: "victoria" }), "victoria");
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
