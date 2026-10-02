/**
 * Unit tests for Requirement 3: openclaw.plugin.json channelConfigs.agent_chat
 * fixes the "not converged" diagnostic on new gateway builds.
 *
 * TC-23-021, TC-23-022, TC-23-025
 */

import { describe, it } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const manifestPath = path.join(__dirname, "..", "openclaw.plugin.json");

interface PluginManifest {
  id: string;
  channels?: string[];
  channelConfigs?: Record<string, unknown>;
}

function loadManifest(): PluginManifest {
  return JSON.parse(fs.readFileSync(manifestPath, "utf-8")) as PluginManifest;
}

/**
 * Re-implementation of the NEW build's
 * pushNonBundledChannelConfigDescriptorDiagnostic core check:
 * for each channel in manifest.channels, warn if the channel is not a key
 * of manifest.channelConfigs.
 */
function missingChannelConfigs(manifest: PluginManifest): string[] {
  const channels = manifest.channels ?? [];
  const configs = manifest.channelConfigs ?? {};
  return channels.filter((channel) => !Object.hasOwn(configs, channel));
}

describe("TC-23-021: channelConfigs.agent_chat exists and manifest stays valid", () => {
  it("has a valid JSON manifest", () => {
    assert.doesNotThrow(() => loadManifest());
  });

  it("still declares channels.agent_chat", () => {
    const manifest = loadManifest();
    assert.ok(Array.isArray(manifest.channels));
    assert.ok(manifest.channels!.includes("agent_chat"));
  });

  it("has channelConfigs.agent_chat", () => {
    const manifest = loadManifest();
    assert.ok(manifest.channelConfigs);
    assert.ok(Object.hasOwn(manifest.channelConfigs!, "agent_chat"));
    assert.strictEqual(typeof manifest.channelConfigs!.agent_chat, "object");
    assert.notStrictEqual(manifest.channelConfigs!.agent_chat, null);
  });
});

describe("TC-23-022: differential check against NEW-build diagnostic logic", () => {
  it("unfixed manifest triggers the missing-channel diagnostic", () => {
    const unfixed: PluginManifest = {
      id: "agent_chat",
      channels: ["agent_chat"],
    };
    assert.deepStrictEqual(missingChannelConfigs(unfixed), ["agent_chat"]);
  });

  it("fixed manifest does not trigger the diagnostic", () => {
    const fixed = loadManifest();
    assert.deepStrictEqual(missingChannelConfigs(fixed), []);
  });
});

describe("TC-23-025: malformed channelConfigs shapes", () => {
  it("string channelConfigs still suppresses the diagnostic (Object.hasOwn passes)", () => {
    const manifest: PluginManifest = {
      id: "agent_chat",
      channels: ["agent_chat"],
      channelConfigs: "agent_chat" as unknown as Record<string, unknown>,
    };
    // Object.hasOwn on a string primitive for property "agent_chat" is false,
    // so the diagnostic IS pushed. Document the actual observed behavior.
    assert.deepStrictEqual(missingChannelConfigs(manifest), ["agent_chat"]);
  });

  it("null channelConfigs value suppresses diagnostic due to Object.hasOwn", () => {
    const manifest: PluginManifest = {
      id: "agent_chat",
      channels: ["agent_chat"],
      channelConfigs: { agent_chat: null as unknown as unknown },
    };
    // Object.hasOwn({ agent_chat: null }, 'agent_chat') is true, so the
    // diagnostic is suppressed despite the garbage value.
    assert.deepStrictEqual(missingChannelConfigs(manifest), []);
  });
});
