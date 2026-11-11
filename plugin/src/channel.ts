import pg from "pg";
import type {
  ChannelPlugin,
  OpenClawConfig,
  ChannelGatewayContext,
  ChannelMeta,
  PluginRuntime,
} from "openclaw/plugin-sdk";
import { loadPgEnv } from "../lib/pg-env.js";
import { getAgentChatRuntime } from "./runtime.js";
import { AgentChatConfigSchema, type ResolvedAgentChatAccount } from "./config.js";

// Resolve agent_chat DB from the nested config section, falling back to flat keys.
// No process.env pollution so child processes/subagents keep their own env.
const pgConfig = loadPgEnv(undefined, "agent_chat");

const { Client } = pg;

const PLUGIN_ID = "agent_chat";

/**
 * Resolve the DB user name from the agent_chat DB config.
 * The DB user is authoritative for message provenance because
 * send_agent_message() enforces sender = session_user.
 */
export function resolveAgentNameFromPgConfig(pgCfg: { user?: string | null }): string {
  const raw = pgCfg.user;
  if (!raw) {
    return "";
  }
  return String(raw).toLowerCase();
}

/** The connected PostgreSQL role used for sends and processed-row ownership. */
export function resolveDbUser(): string {
  return resolveAgentNameFromPgConfig(pgConfig);
}

function normalizeAgentId(raw: unknown): string {
  if (typeof raw !== "string" || !raw) {
    return "";
  }
  return raw.toLowerCase();
}

function resolveSoleConfiguredAgentId(cfg: OpenClawConfig): string | undefined {
  const entries = (cfg as { agents?: { entries?: Record<string, unknown> } }).agents?.entries;
  if (entries && typeof entries === "object" && !Array.isArray(entries)) {
    const keys = Object.keys(entries);
    if (keys.length === 1) {
      return normalizeAgentId(keys[0]);
    }
    for (const key of keys) {
      const entry = entries[key] as { default?: boolean } | undefined;
      if (entry?.default === true) {
        return normalizeAgentId(key);
      }
    }
  }

  const list = (cfg as { agents?: { list?: Array<{ id?: string; default?: boolean }> } }).agents
    ?.list;
  if (Array.isArray(list)) {
    if (list.length === 1) {
      return normalizeAgentId(list[0]?.id);
    }
    for (const entry of list) {
      if (entry?.default === true) {
        return normalizeAgentId(entry.id);
      }
    }
  }

  return undefined;
}

function resolveExplicitAgentIdFromChannelConfig(
  cfg: OpenClawConfig,
  accountId?: string,
): string | undefined {
  const channelConfig = (cfg as { channels?: { agent_chat?: unknown } }).channels?.agent_chat;
  if (!channelConfig || typeof channelConfig !== "object" || Array.isArray(channelConfig)) {
    return undefined;
  }
  const topLevel = (channelConfig as { agentId?: string }).agentId;
  if (topLevel) {
    return normalizeAgentId(topLevel);
  }
  const accounts = (channelConfig as { accounts?: Record<string, { agentId?: string }> }).accounts;
  if (accounts && typeof accounts === "object") {
    const id = accountId && accountId !== "default" ? accountId : "default";
    const account = accounts[id];
    if (account?.agentId) {
      return normalizeAgentId(account.agentId);
    }
  }
  return undefined;
}

/**
 * Resolve the OpenClaw gateway agent id that should own agent_chat sessions.
 *
 * The dispatch runtime matches the `agent:<id>:...` session key against
 * configured gateway agents, so this id must be the gateway's own agent id
 * (e.g. "main"), not the PostgreSQL role name used for the bus connection.
 *
 * Resolution order:
 *   1. Explicit `channels.agent_chat.agentId` (or per-account `agentId`).
 *   2. Sole or default agent from `cfg.agents.entries` / `cfg.agents.list`.
 *   3. Fallback to the DB user for backward compatibility.
 */
export function resolveGatewayAgentId(
  cfg?: OpenClawConfig,
  accountId?: string,
): string {
  if (cfg) {
    const explicit = resolveExplicitAgentIdFromChannelConfig(cfg, accountId);
    if (explicit) {
      return explicit;
    }
    const sole = resolveSoleConfiguredAgentId(cfg);
    if (sole) {
      return sole;
    }
  }
  return resolveDbUser();
}

/**
 * @deprecated Use resolveDbUser() for the DB role or resolveGatewayAgentId(cfg)
 * for the dispatch/session agent id.
 */
export function resolveAgentName(_cfg?: OpenClawConfig): string {
  return resolveDbUser();
}

/** Result of validating the agent_chat plugin configuration. */
export type AgentChatConfigValidation =
  | { ok: true; dbUser: string; gatewayAgentId: string }
  | { ok: false; error: string };

/**
 * Validate that the plugin has enough configuration to start monitoring.
 * Requires both a DB user (for message provenance) and a gateway agent id
 * (for dispatch/session ownership).
 */
export function validateAgentChatConfig(cfg?: OpenClawConfig): AgentChatConfigValidation {
  const dbUser = resolveDbUser();
  if (!dbUser) {
    return {
      ok: false,
      error:
        "agent_chat: cannot start monitor — no DB user could be resolved from " +
        "the DB config (pgConfig.user). Please set agent_chat.user in postgres.json " +
        "or the PGUSER environment variable.",
    };
  }
  const gatewayAgentId = resolveGatewayAgentId(cfg);
  if (!gatewayAgentId) {
    return {
      ok: false,
      error:
        "agent_chat: cannot start monitor — no gateway agent id could be resolved. " +
        "Please configure a sole/default agent, set channels.agent_chat.agentId, " +
        "or ensure agent_chat.user matches a configured gateway agent id.",
    };
  }
  return { ok: true, dbUser, gatewayAgentId };
}

/** Input to the inbound envelope formatter. */
export interface AgentChatEnvelopeInput {
  channel: string;
  from: string;
  timestamp?: number;
  body: string;
  chatType: "direct" | "group";
  sender: { name: string; id: string };
  envelope: unknown;
}

/** Result of attempting to format an inbound envelope. */
export type AgentChatEnvelopeResult =
  | { ok: true; body: string }
  | { ok: false; error: string };

/**
 * Format an inbound envelope, feature-detecting the gateway build.
 *
 * OLD build (<= 436c9a3): `runtime.channel.reply.formatInboundEnvelope` is
 * present and used directly.
 *
 * NEW build (>= d6c4379): `formatInboundEnvelope` is removed from the plugin
 * runtime surface. Fall back to `formatAgentEnvelope` with a shim body of
 * `"${sender}: ${body}"`, which matches the OLD build's output for direct
 * chats.
 */
export function formatAgentChatEnvelope(
  runtime: PluginRuntime,
  cfg: OpenClawConfig,
  message: {
    sender: string;
    message: string;
    timestamp?: Date | string | number | null;
  },
): AgentChatEnvelopeResult {
  const replyApi = runtime.channel?.reply;
  if (!replyApi) {
    return { ok: false, error: "runtime.channel.reply is not available" };
  }

  const envelopeOptions =
    typeof replyApi.resolveEnvelopeFormatOptions === "function"
      ? replyApi.resolveEnvelopeFormatOptions(cfg)
      : {};

  const timestampMs = message.timestamp
    ? new Date(message.timestamp).getTime()
    : undefined;

  const baseInput = {
    channel: "AgentChat",
    from: `${message.sender}`,
    timestamp: timestampMs,
    chatType: "direct" as const,
    sender: { name: message.sender, id: message.sender },
    envelope: envelopeOptions,
  };

  if (typeof replyApi.formatInboundEnvelope === "function") {
    try {
      const body = replyApi.formatInboundEnvelope({
        ...baseInput,
        body: message.message,
      });
      return { ok: true, body };
    } catch (err) {
      return {
        ok: false,
        error: `formatInboundEnvelope threw: ${(err as Error).message}`,
      };
    }
  }

  if (typeof replyApi.formatAgentEnvelope === "function") {
    try {
      const shimBody = `${message.sender}: ${message.message}`;
      const body = replyApi.formatAgentEnvelope({
        ...baseInput,
        body: shimBody,
      });
      return { ok: true, body };
    } catch (err) {
      return {
        ok: false,
        error: `formatAgentEnvelope shim threw: ${(err as Error).message}`,
      };
    }
  }

  return {
    ok: false,
    error:
      "Neither formatInboundEnvelope nor formatAgentEnvelope is available on runtime.channel.reply",
  };
}

/** Result of checking that deprecated reply functions still exist. */
export type DeprecatedReplyFunctionsCheck =
  | { ok: true }
  | { ok: false; error: string; missing: string[] };

/**
 * Feature-detect the deprecated runtime functions the plugin still depends on.
 * These are marked `removeAfter: 2026-10-01` on newer gateway builds. If any
 * are missing the message must be marked failed, never allowed to throw an
 * unhandled TypeError.
 */
export function checkDeprecatedReplyFunctions(
  runtime: PluginRuntime,
): DeprecatedReplyFunctionsCheck {
  const replyApi = runtime.channel?.reply;
  const missing: string[] = [];

  if (typeof replyApi?.finalizeInboundContext !== "function") {
    missing.push("finalizeInboundContext");
  }
  if (typeof replyApi?.createReplyDispatcherWithTyping !== "function") {
    missing.push("createReplyDispatcherWithTyping");
  }
  if (typeof replyApi?.dispatchReplyFromConfig !== "function") {
    missing.push("dispatchReplyFromConfig");
  }

  if (missing.length > 0) {
    return {
      ok: false,
      error: `runtime.channel.inbound.dispatch not yet wired / required functions removed: ${missing.join(", ")}`,
      missing,
    };
  }

  return { ok: true };
}

// Manual meta definition since "agent_chat" is not in the core channel allowlist
const meta: Omit<ChannelMeta, "id"> = {
  label: "Agent Chat",
  selectionLabel: "Agent Chat",
  docsPath: "/channels/agent_chat",
  blurb: "PostgreSQL-based agent messaging via agent_chat table",
  order: 999,
};

/**
 * Create PostgreSQL client with direct config pass-through
 * avoiding environment variable pollution for child processes.
 */
export function createPgClient(): pg.Client {
  return new Client(pgConfig);
}

/**
 * Fetch unprocessed messages for this agent from agent_chat table
 */
async function fetchUnprocessedMessages(client: pg.Client, agentName: string) {
  const query = `
    SELECT ac.id, ac.sender, ac.message, ac.recipients, ac.reply_to, ac."timestamp"
    FROM agent_chat ac
    LEFT JOIN agent_chat_processed acp ON ac.id = acp.chat_id AND LOWER(acp.agent) = LOWER($1)
    WHERE (LOWER($1) = ANY(SELECT LOWER(unnest(ac.recipients)))
        OR '*' = ANY(ac.recipients))
      AND acp.chat_id IS NULL
    ORDER BY ac."timestamp" ASC
  `;

  const result = await client.query(query, [agentName]);
  return result.rows;
}

/**
 * Atomically claim a message for this agent.
 *
 * Uses INSERT ... ON CONFLICT DO NOTHING RETURNING so only the worker that
 * actually creates the row proceeds to dispatch. A pre-existing row (from a
 * concurrent worker, a prior partial run, or any terminal status) causes the
 * caller to skip dispatch.
 */
export async function claimMessage(
  client: pg.Client,
  chatId: number,
  agentName: string,
): Promise<{ chat_id: number; agent: string; status: string } | null> {
  const query = `
    INSERT INTO public.agent_chat_processed (chat_id, agent, status, received_at)
    VALUES ($1, LOWER($2), 'received', NOW())
    ON CONFLICT (chat_id, agent) DO NOTHING
    RETURNING chat_id, agent, status
  `;

  const result = await client.query(query, [chatId, agentName]);
  return result.rows[0] ?? null;
}

/**
 * Mark message as routed (passed to agent session)
 */
async function markMessageRouted(client: pg.Client, chatId: number, agentName: string) {
  const query = `
    UPDATE agent_chat_processed
    SET status = 'routed', routed_at = NOW()
    WHERE chat_id = $1
      AND LOWER(agent) = LOWER($2)
      -- Terminal statuses never regress. This protects against a downstream
      -- "success" transition clobbering a terminal status already written
      -- earlier in the same reply cycle.
      AND status NOT IN ('responded', 'expired', 'handled', 'skipped', 'failed')
  `;

  await client.query(query, [chatId, agentName]);
}

/**
 * Mark message as failed with error
 */
async function markMessageFailed(
  client: pg.Client,
  chatId: number,
  agentName: string,
  errorMsg: string,
) {
  const query = `
    UPDATE agent_chat_processed
    SET status = 'failed', error_message = $3
    WHERE chat_id = $1 AND LOWER(agent) = LOWER($2)
      -- Terminal statuses never regress; only move received/routed rows to
      -- failed.
      AND status NOT IN ('responded', 'expired', 'handled', 'skipped', 'failed')
  `;

  await client.query(query, [chatId, agentName, errorMsg]);
}

/**
 * Insert outbound message into agent_chat via send_agent_message()
 */
export async function insertOutboundMessage(
  client: pg.Client,
  {
    sender,
    message,
    recipients,
    replyTo,
  }: {
    sender: string;
    message: string;
    recipients: string[];
    replyTo: number | null;
  },
) {
  // All inserts must go through send_agent_message() — direct INSERT is blocked.
  // reply_to is carried in the same SECURITY DEFINER call so the insert is
  // atomic (no separate UPDATE that can fail after the body commits).
  const result = await client.query(
    `SELECT send_agent_message($1::text, $2::text, $3::text[], p_ttl => $4::interval, p_reply_to => $5::integer) AS id`,
    [sender, message, recipients, null, replyTo],
  );

  const newId: number = result.rows[0].id;

  return { id: newId };
}

/**
 * Sanitize a peer name for use in a session key.
 *
 * Lowercase and replace any character outside [a-z0-9_-] with an underscore.
 */
export function sanitizeSessionPeer(peer: string): string {
  return peer.toLowerCase().replace(/[^a-z0-9_-]/g, "_");
}

/**
 * Build the persistent per-peer session label.
 *
 * Format: agent:<self>:agent_chat:<peer>
 */
export function buildSessionLabel({
  agentName,
  peer,
}: {
  agentName: string;
  peer: string;
}): string {
  return `agent:${agentName}:agent_chat:${sanitizeSessionPeer(peer)}`;
}

/**
 * Build the first-line wake instruction that is prepended to the inbound Body.
 */
export function buildWakeLine(
  messageId: number,
  sender: string,
  isBroadcast: boolean,
): string {
  const broadcastHint = isBroadcast ? " (broadcast)" : "";
  return (
    `[agent_chat #${messageId} from ${sender}${broadcastHint}] ` +
    "Nothing you write here is sent automatically. " +
    `Reply: agent_chat_send({to:'${sender}', text, replyTo:${messageId}}). ` +
    `No reply needed: agent_chat_mark({ids:[${messageId}], status:'handled'}) (or 'skipped').`
  );
}

/**
 * Check whether this agent has currently muted the sender.
 */
async function isPeerMuted(
  client: pg.Client,
  agentName: string,
  sender: string,
): Promise<boolean> {
  const result = await client.query<{ muted: boolean }>(
    `SELECT agent_chat_is_muted($1::text, $2::text) AS muted`,
    [agentName, sender],
  );
  return result.rows[0]?.muted === true;
}

function truncateForLog(text: string, maxLen = 120): string {
  const normalized = text.replace(/\s+/g, " ").trim();
  if (normalized.length <= maxLen) {
    return normalized;
  }
  return normalized.slice(0, maxLen - 1) + "…";
}

/** Shape of a breaker alert row returned by agent_chat_pending_alerts. */
export interface AgentChatBreakerAlert {
  alert_id: number;
  pair_a: string;
  pair_b: string;
  window_start: Date;
  window_end: Date;
  message_count: number;
  threshold: number;
  created_at: Date;
}

function formatIntervalWindow(windowStart: Date, windowEnd: Date): string {
  const seconds = Math.max(
    0,
    Math.round((new Date(windowEnd).getTime() - new Date(windowStart).getTime()) / 1000),
  );
  if (seconds < 60) {
    return `${seconds}s`;
  }
  const minutes = Math.floor(seconds / 60);
  const remSeconds = seconds % 60;
  if (remSeconds === 0) {
    return `${minutes}m`;
  }
  return `${minutes}m ${remSeconds}s`;
}

/**
 * Inject a breaker alert as a wake into the per-peer session for the OTHER
 * agent in the pair. The alert is marked seen ONLY after the dispatch succeeds
 * so a failed injection remains pending and can be retried.
 */
export async function injectBreakerAlert(options: {
  alert: AgentChatBreakerAlert;
  client: pg.Client;
  dbUser: string;
  gatewayAgentId: string;
  cfg: OpenClawConfig;
  ctx: ChannelGatewayContext<ResolvedAgentChatAccount>;
  runtime: PluginRuntime;
}) {
  const { alert, client, dbUser, gatewayAgentId, cfg, ctx, runtime } = options;
  const log = ctx.log;

  // Determine the peer (the other agent in the pair). Alert pair names are
  // bus identities (DB roles), so compare against the DB user, not the
  // gateway agent id.
  const peer =
    alert.pair_a.toLowerCase() === dbUser.toLowerCase()
      ? alert.pair_b
      : alert.pair_a;

  if (!peer || peer.toLowerCase() === dbUser.toLowerCase()) {
    log?.debug?.(`Breaker alert ${alert.alert_id} has no distinct peer; skipping injection`);
    return;
  }

  const windowText = formatIntervalWindow(alert.window_start, alert.window_end);
  const alertText =
    `Loop check: you and ${peer} exchanged ${alert.message_count} agent_chat messages within ${windowText}. ` +
    "If this is real work, continue. " +
    `If it's a loop, call agent_chat_mute({peer:'${peer}', minutes, reason}) and stop sending.`;

  const check = checkDeprecatedReplyFunctions(runtime);
  if (!check.ok) {
    log?.error?.(`agent_chat: cannot inject breaker alert: ${check.error}`);
    return;
  }

  const sessionLabel = buildSessionLabel({ agentName: gatewayAgentId, peer });

  const ctxPayload = runtime.channel.reply.finalizeInboundContext({
    Body: alertText,
    RawBody: alertText,
    CommandBody: alertText,
    From: "agent_chat",
    SessionKey: sessionLabel,
    ChatType: "direct",
    ConversationLabel: peer,
    SenderName: "agent_chat",
    SenderId: "agent_chat",
    Provider: "agent_chat",
    Surface: "agent_chat",
    MessageSid: `breaker-${alert.alert_id}`,
    Timestamp: Date.now(),
    OriginatingChannel: "agent_chat",
    // Intentionally NO OriginatingTo: agent_chat is a messaging system, not a
    // session manager, so the woken session must not use agent_chat as a reply
    // or announce origin.
  });

  const { dispatcher, replyOptions, markDispatchIdle } =
    runtime.channel.reply.createReplyDispatcherWithTyping({
      deliver: async (payload, _info) => {
        const preview = truncateForLog(payload.text ?? "");
        log?.info?.(
          `Suppressing automatic agent_chat reply for breaker alert ${alert.alert_id}: ${preview}`,
        );
      },
      onError: (err, info) => {
        log?.error?.(`${info.kind} breaker alert reply failed: ${err}`);
      },
    });

  try {
    await runtime.channel.reply.dispatchReplyFromConfig({
      ctx: ctxPayload,
      cfg,
      dispatcher,
      replyOptions,
    });
    markDispatchIdle();

    // Mark the alert seen only after successful injection. A failed dispatch
    // leaves seen_at NULL so the next poll/notification retries it.
    await client.query(`SELECT agent_chat_mark_alerts_seen($1::int[])`, [
      [alert.alert_id],
    ]);

    log?.info?.(`Breaker alert ${alert.alert_id} injected into session ${sessionLabel}`);
    await dispatcher.waitForIdle();
  } catch (err) {
    log?.error?.(`Failed to inject breaker alert ${alert.alert_id}: ${err}`);
  }
}

/**
 * Fetch and inject any unseen breaker alerts involving this agent.
 */
async function checkPendingAlerts(
  client: pg.Client,
  dbUser: string,
  cfg: OpenClawConfig,
  ctx: ChannelGatewayContext<ResolvedAgentChatAccount>,
  runtime: PluginRuntime,
) {
  const result = await client.query<AgentChatBreakerAlert>(
    `SELECT * FROM agent_chat_pending_alerts($1::text)`,
    [dbUser],
  );
  for (const alert of result.rows) {
    await injectBreakerAlert({ alert, client, dbUser, gatewayAgentId: resolveGatewayAgentId(cfg, ctx.account?.accountId), cfg, ctx, runtime });
  }
}

/**
 * Process a single message from agent_chat
 */
export async function processAgentChatMessage({
  message,
  client,
  dbUser,
  gatewayAgentId,
  cfg,
  ctx,
}: {
  message: {
    id: number;
    sender: string;
    message: string;
    recipients: string[];
    reply_to: number | null;
    timestamp: Date;
  };
  client: pg.Client;
  dbUser: string;
  gatewayAgentId: string;
  cfg: OpenClawConfig;
  ctx: ChannelGatewayContext<ResolvedAgentChatAccount>;
}) {
  const log = ctx.log;
  const runtime = getAgentChatRuntime();

  log?.info?.(`Processing message ${message.id} from ${message.sender}`);

  // Self-mention guard: prevent infinite loops. Compare against the DB role
  // because sender names are bus identities, not gateway agent ids.
  if (message.sender.toLowerCase() === dbUser.toLowerCase()) {
    log?.debug?.(`Skipping self-mention from ${message.sender}`);
    await claimMessage(client, message.id, dbUser);
    return;
  }

  try {
    // Mute check before waking. If the peer is muted we still claim the
    // message (so it does not keep being picked up) and leave it at 'routed'
    // without dispatching a turn.
    const muted = await isPeerMuted(client, dbUser, message.sender);
    if (muted) {
      log?.info?.(
        `Message ${message.id} from ${message.sender} suppressed: peer is muted`,
      );
      await claimMessage(client, message.id, dbUser);
      await markMessageRouted(client, message.id, dbUser);
      return;
    }

    // Atomically claim the message. Only the first worker/call creates the row.
    const claim = await claimMessage(client, message.id, dbUser);
    if (!claim) {
      log?.debug?.(
        `Message ${message.id} already claimed by another worker or a prior run; skipping dispatch`,
      );
      return;
    }
    log?.debug?.(`Marked message ${message.id} as received`);

    // Format the inbound message envelope with build-aware feature detection.
    const envelopeResult = formatAgentChatEnvelope(runtime, cfg, {
      sender: message.sender,
      message: message.message,
      timestamp: message.timestamp,
    });

    if (!envelopeResult.ok) {
      log?.error?.(
        `agent_chat: envelope formatting failed for message ${message.id}: ${envelopeResult.error}`,
      );
      await markMessageFailed(client, message.id, dbUser, envelopeResult.error);
      return;
    }

    const isBroadcast = message.recipients.includes("*");
    const wakeLine = buildWakeLine(message.id, message.sender, isBroadcast);
    // The wake line is the first line of Body only. RawBody and CommandBody
    // stay as the peer's text so slash-command injection risk stays isolated.
    const body = `${wakeLine}\n\n${envelopeResult.body}`;

    // Feature-detect the deprecated reply functions before calling them.
    const funcCheck = checkDeprecatedReplyFunctions(runtime);
    if (!funcCheck.ok) {
      log?.error?.(`agent_chat: ${funcCheck.error}`);
      await markMessageFailed(client, message.id, dbUser, funcCheck.error);
      return;
    }

    const sessionLabel = buildSessionLabel({ agentName: gatewayAgentId, peer: message.sender });

    const ctxPayload = runtime.channel.reply.finalizeInboundContext({
      Body: body,
      RawBody: message.message,
      CommandBody: message.message,
      From: `agent_chat:${message.sender}`,
      SessionKey: sessionLabel,
      ChatType: isBroadcast ? "group" : "direct",
      ConversationLabel: `${message.sender}`,
      SenderName: message.sender,
      SenderId: message.sender,
      Provider: "agent_chat",
      Surface: "agent_chat",
      MessageSid: String(message.id),
      Timestamp: message.timestamp ? new Date(message.timestamp).getTime() : undefined,
      OriginatingChannel: "agent_chat",
      // Intentionally NO OriginatingTo. agent_chat is a messaging system, not a
      // session manager. Removing the reply/announce origin means subagent
      // completions, cron and heartbeat announces have no deliverable route to
      // a peer through this channel.
    });

    // Create reply dispatcher whose deliver() only logs. No turn output ever
    // reaches a peer automatically: final text, empty turns, NO_REPLY,
    // ANNOUNCE_SKIP, fallback summaries, block/tool/media chunks and error
    // payloads are all dropped after logging a truncated preview.
    const { dispatcher, replyOptions, markDispatchIdle } =
      runtime.channel.reply.createReplyDispatcherWithTyping({
        deliver: async (payload, _info) => {
          const preview = truncateForLog(payload.text ?? "");
          log?.info?.(
            `Suppressing automatic agent_chat reply for message ${message.id}: ${preview}`,
          );
        },
        onError: (err, info) => {
          log?.error?.(`${info.kind} reply failed: ${err}`);
        },
      });

    // Dispatch the message to the agent using dispatchReplyFromConfig
    log?.info?.(`🚀 Dispatching message ${message.id} to agent...`);

    try {
      await runtime.channel.reply.dispatchReplyFromConfig({
        ctx: ctxPayload,
        cfg,
        dispatcher,
        replyOptions,
      });

      markDispatchIdle();

      log?.info?.(`✅ Successfully dispatched message ${message.id}`);
      await markMessageRouted(client, message.id, dbUser);

      // Wait for any async deliver() work to finish before returning.
      await dispatcher.waitForIdle();
    } catch (dispatchError) {
      log?.error?.(`❌ Dispatch error for message ${message.id}: ${dispatchError}`);
      await markMessageFailed(
        client,
        message.id,
        dbUser,
        (dispatchError as Error).message,
      );
    }
  } catch (error) {
    // Mark as failed if routing fails
    await markMessageFailed(client, message.id, dbUser, (error as Error).message);
    log?.error?.(`Failed to route message ${message.id}: ${error}`);
  }
}

/**
 * Start monitoring agent_chat for this account
 */
async function startAgentChatMonitor(
  ctx: ChannelGatewayContext<ResolvedAgentChatAccount>,
): Promise<void> {
  const { pollIntervalMs } = ctx.account.config;
  const log = ctx.log;

  const validation = validateAgentChatConfig(ctx.cfg);
  if (!validation.ok) {
    log?.error?.(validation.error);
    throw new Error(validation.error);
  }
  const { dbUser, gatewayAgentId } = validation;

  log?.info?.(`Starting monitor for DB user ${dbUser} / gateway agent ${gatewayAgentId}`);

  const client = createPgClient();
  const runtime = getAgentChatRuntime();

  try {
    await client.connect();
    log?.info?.(
      `Connected to PostgreSQL host=${pgConfig.host ?? "localhost"} database=${pgConfig.database ?? "<unset>"}`,
    );

    // Listen to agent_chat channel
    await client.query("LISTEN agent_chat");
    log?.info?.(`Listening on channel 'agent_chat'`);

    // Listen to breaker alert channel
    await client.query("LISTEN agent_chat_breaker_alert");
    log?.info?.(`Listening on channel 'agent_chat_breaker_alert'`);

    // Handle notifications
    client.on("notification", async (msg) => {
      if (msg.channel === "agent_chat") {
        log?.debug?.(`Received notification`);

        try {
          // Check breaker alerts before waking on new messages.
          await checkPendingAlerts(client, dbUser, ctx.cfg, ctx, runtime);

          const messages = await fetchUnprocessedMessages(client, dbUser);

          for (const message of messages) {
            await processAgentChatMessage({
              message,
              client,
              dbUser,
              gatewayAgentId,
              cfg: ctx.cfg,
              ctx,
            });
          }
        } catch (error) {
          log?.error?.(`Error processing notification: ${error}`);
        }
      } else if (msg.channel === "agent_chat_breaker_alert") {
        log?.debug?.(`Received breaker alert notification`);
        try {
          await checkPendingAlerts(client, dbUser, ctx.cfg, ctx, runtime);
        } catch (error) {
          log?.error?.(`Error processing breaker alert notification: ${error}`);
        }
      }
    });

    // Initial check for existing breaker alerts and unprocessed messages
    await checkPendingAlerts(client, dbUser, ctx.cfg, ctx, runtime);

    const initialMessages = await fetchUnprocessedMessages(client, dbUser);
    log?.info?.(`Found ${initialMessages.length} unprocessed messages on startup`);

    for (const message of initialMessages) {
      await processAgentChatMessage({
        message,
        client,
        dbUser,
        gatewayAgentId,
        cfg: ctx.cfg,
        ctx,
      });
    }

    // Keep connection alive
    const keepAliveInterval = setInterval(() => {
      if (!ctx.abortSignal?.aborted) {
        client.query("SELECT 1").catch((err) => {
          log?.error?.(`Keep-alive failed: ${err}`);
        });
      }
    }, pollIntervalMs);

    // Handle abort signal
    if (ctx.abortSignal) {
      ctx.abortSignal.addEventListener("abort", async () => {
        log?.info?.(`Received abort signal`);
        clearInterval(keepAliveInterval);
        try {
          await client.query("UNLISTEN agent_chat");
          await client.query("UNLISTEN agent_chat_breaker_alert");
          await client.end();
          log?.info?.(`Disconnected from PostgreSQL`);
        } catch (error) {
          log?.error?.(`Error during shutdown: ${error}`);
        }
      });
    }

    // Wait for abort
    return new Promise<void>((resolve) => {
      if (ctx.abortSignal) {
        ctx.abortSignal.addEventListener("abort", () => resolve());
      }
    });
  } catch (error) {
    log?.error?.(
      `agent_chat: fatal error connecting to PostgreSQL ` +
      `host=${pgConfig.host ?? "localhost"} database=${pgConfig.database ?? "<unset>"}: ${error}`,
    );
    try {
      await client.end();
    } catch (cleanupError) {
      // Ignore cleanup errors
    }
    throw error;
  }
}

/**
 * Normalize agent_chat messaging target
 */
function normalizeAgentChatMessagingTarget(raw: string): string | undefined {
  const trimmed = raw.trim();
  if (!trimmed) return undefined;

  let normalized = trimmed;

  // Strip 'agent_chat:' prefix (case-insensitive)
  if (normalized.toLowerCase().startsWith("agent_chat:")) {
    normalized = normalized.slice("agent_chat:".length).trim();
  }
  // Strip 'agent:' prefix (case-insensitive)
  else if (normalized.toLowerCase().startsWith("agent:")) {
    normalized = normalized.slice("agent:".length).trim();
  }

  if (!normalized) return undefined;

  return normalized;
}

/**
 * Check if raw string looks like an agent_chat target ID
 */
function looksLikeAgentChatTargetId(raw: string): boolean {
  const trimmed = raw.trim();
  if (!trimmed) return false;

  // Accept 'agent:' or 'agent_chat:' prefixes
  if (/^(agent_chat:|agent:)/i.test(trimmed)) return true;

  // Accept bare agent names (alphanumeric, underscore, hyphen)
  return /^[a-zA-Z0-9_-]+$/.test(trimmed);
}

/**
 * Agent Chat Channel Plugin
 */
export const agentChatPlugin: ChannelPlugin<ResolvedAgentChatAccount> = {
  id: PLUGIN_ID,

  meta: {
    id: PLUGIN_ID,
    ...meta,
  },

  capabilities: {
    chatTypes: ["direct", "group"],
    media: false,
    reactions: false,
    threads: false,
  },

  reload: {
    configPrefixes: ["channels.agent_chat"],
  },

  configSchema: AgentChatConfigSchema,

  messaging: {
    normalizeTarget: normalizeAgentChatMessagingTarget,
    targetResolver: {
      looksLikeId: looksLikeAgentChatTargetId,
      hint: "<AgentName|agent:AgentName|agent_chat:AgentName>",
    },
  },

  config: {
    listAccountIds: (cfg) => {
      const channelConfig = cfg.channels?.agent_chat;
      if (!channelConfig) return [];

      const accounts = ["default"];
      if (channelConfig.accounts) {
        accounts.push(...Object.keys(channelConfig.accounts));
      }
      return accounts;
    },

    resolveAccount: (cfg, accountId) => {
      const channelConfig = cfg.channels?.agent_chat;

      if (!channelConfig) {
        return {
          accountId: accountId || "default",
          name: accountId || "default",
          enabled: false,
          config: {
            pollIntervalMs: 1000,
          },
        } as ResolvedAgentChatAccount;
      }

      const normalizedAccountId = accountId || "default";
      const config =
        normalizedAccountId === "default"
          ? channelConfig
          : channelConfig.accounts?.[normalizedAccountId] || {};

      return {
        accountId: normalizedAccountId,
        name: config.name || normalizedAccountId,
        enabled: config.enabled !== false,
        config: {
          pollIntervalMs: config.pollIntervalMs || 1000,
        },
      } as ResolvedAgentChatAccount;
    },

    defaultAccountId: () => "default",

    isConfigured: (_account, cfg) =>
      Boolean(resolveDbUser()) && Boolean(resolveGatewayAgentId(cfg)),

    describeAccount: (account, cfg) => {
      return {
        accountId: account.accountId,
        name: account.name,
        enabled: account.enabled,
        configured:
          Boolean(resolveDbUser()) && Boolean(resolveGatewayAgentId(cfg)),
        agentName: resolveGatewayAgentId(cfg, account.accountId),
        dbUser: resolveDbUser(),
        database: pgConfig.database ?? null,
        host: pgConfig.host ?? "localhost",
      };
    },
  },

  outbound: {
    deliveryMode: "direct",
    textChunkLimit: 4000, // PostgreSQL text field - generous limit

    sendText: async ({ cfg, to, text, accountId }) => {
      const account = agentChatPlugin.config!.resolveAccount(cfg, accountId);

      if (!agentChatPlugin.config!.isConfigured?.(account, cfg)) {
        throw new Error(`agent_chat account ${accountId} not configured`);
      }

      const client = createPgClient();

      try {
        await client.connect();

        const dbUser = resolveDbUser();
        if (!dbUser) {
          throw new Error(
            `agent_chat: cannot send — no DB user could be resolved from pgConfig.user`,
          );
        }

        // 'to' is the recipient agent name (format: "agent_chat:AgentName", "agent:AgentName", or bare "AgentName")
        const recipientName = normalizeAgentChatMessagingTarget(to) || to;

        const result = await insertOutboundMessage(client, {
          sender: dbUser,
          message: text,
          recipients: [recipientName],
          replyTo: null,
        });

        return {
          channel: PLUGIN_ID,
          messageId: String(result.id),
          success: true,
        };
      } finally {
        await client.end();
      }
    },
  },

  gateway: {
    startAccount: async (ctx) => {
      return await startAgentChatMonitor(ctx);
    },
  },

  status: {
    defaultRuntime: {
      accountId: "default",
      running: false,
      lastStartAt: null,
      lastStopAt: null,
      lastError: null,
    },

    buildChannelSummary: ({ snapshot }) => ({
      configured: snapshot.configured ?? false,
      running: snapshot.running ?? false,
      // agentName and database stored in probe for custom display
      agentName: (snapshot.probe as { agentName?: string })?.agentName ?? null,
      database: (snapshot.probe as { database?: string })?.database ?? null,
    }),

    buildAccountSnapshot: ({ account, runtime, cfg }) => {
      return {
        accountId: account.accountId,
        name: account.name,
        enabled: account.enabled,
        configured:
          Boolean(resolveDbUser()) && Boolean(resolveGatewayAgentId(cfg)),
        running: runtime?.running ?? false,
        lastStartAt: runtime?.lastStartAt ?? null,
        lastStopAt: runtime?.lastStopAt ?? null,
        lastError: runtime?.lastError ?? null,
        // Store custom info in probe
        probe: {
          agentName: resolveGatewayAgentId(cfg, account.accountId),
          dbUser: resolveDbUser(),
          database: pgConfig.database ?? null,
        },
      };
    },
  },
};
