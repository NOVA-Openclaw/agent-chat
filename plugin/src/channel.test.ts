/**
 * Unit tests for buildErrorBannerSuppressionMessages() — the emit-boundary
 * decision that suppresses failed-turn error banners from being written to
 * agent_chat instead of logging them.
 *
 * See: nova-openclaw/agent-chat#20 ("channel.js deliver(): failed-turn error
 * banners transmitted to peers instead of logged — no errorContext
 * suppression at emit boundary").
 *
 * Framework: Node built-in test runner + tsx.
 * Run: npx tsx --test src/channel.test.ts
 */

import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { buildErrorBannerSuppressionMessages } from "./channel.js";

describe("buildErrorBannerSuppressionMessages", () => {
  it("includes the message id, sender, kind, and banner text in the log message", () => {
    const { logMessage } = buildErrorBannerSuppressionMessages({
      messageId: 42,
      sender: "newhart",
      kind: "final",
      bannerText: "⚠️ API provider returned a billing error",
    });

    assert.match(logMessage, /message 42/);
    assert.match(logMessage, /sender=newhart/);
    assert.match(logMessage, /kind=final/);
    assert.match(logMessage, /⚠️ API provider returned a billing error/);
  });

  it("produces a distinct failure-status message that also carries the banner text", () => {
    const { failureMessage } = buildErrorBannerSuppressionMessages({
      messageId: 7,
      sender: "victoria",
      kind: "block",
      bannerText: "billing error",
    });

    assert.match(failureMessage, /Suppressed error banner/);
    assert.match(failureMessage, /billing error/);
  });

  it("handles an empty banner text without throwing", () => {
    const { logMessage, failureMessage } = buildErrorBannerSuppressionMessages({
      messageId: 1,
      sender: "nova",
      kind: "tool",
      bannerText: "",
    });

    assert.equal(typeof logMessage, "string");
    assert.equal(typeof failureMessage, "string");
  });
});
