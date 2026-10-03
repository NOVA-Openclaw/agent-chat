import pg from "pg";
import type {
  OpenClawConfig,
  OpenClawPluginService,
  OpenClawPluginServiceContext,
  PluginRuntime,
} from "openclaw/plugin-sdk";

const DIGEST_CAP = 20;

/** Message row as seen by the startup digest query. */
export interface UnresolvedMessage {
  id: number;
  sender: string;
  message: string;
  recipients: string[];
  reply_to: number | null;
  timestamp: Date;
  status: string | null;
}

/**
 * Fetch unresolved messages for this agent, oldest first, up to the cap.
 *
 * Unresolved means:
 *   - the agent is a named recipient (or the message is a broadcast), AND
 *   - there is no agent_chat_processed row for this agent, OR the row is in
 *     a non-terminal status ('received' or 'routed').
 */
export async function fetchUnresolvedMessages(
  client: pg.Client,
  agentName: string,
  limit: number,
): Promise<UnresolvedMessage[]> {
  const query = `
    SELECT ac.id, ac.sender, ac.message, ac.recipients, ac.reply_to, ac."timestamp", acp.status
    FROM agent_chat ac
    LEFT JOIN agent_chat_processed acp
      ON ac.id = acp.chat_id AND LOWER(acp.agent) = LOWER($1)
    WHERE (
        LOWER($1) = ANY(SELECT LOWER(unnest(ac.recipients)))
        OR '*' = ANY(ac.recipients)
      )
      AND (
        acp.chat_id IS NULL
        OR acp.status IN ('received', 'routed')
      )
    ORDER BY ac."timestamp" ASC
    LIMIT $2
  `;

  const result = await client.query(query, [agentName, limit]);
  return result.rows;
}

/** Count all unresolved messages for this agent (ignoring the cap). */
export async function countUnresolvedMessages(
  client: pg.Client,
  agentName: string,
): Promise<number> {
  const query = `
    SELECT COUNT(*)::int AS cnt
    FROM agent_chat ac
    LEFT JOIN agent_chat_processed acp
      ON ac.id = acp.chat_id AND LOWER(acp.agent) = LOWER($1)
    WHERE (
        LOWER($1) = ANY(SELECT LOWER(unnest(ac.recipients)))
        OR '*' = ANY(ac.recipients)
      )
      AND (
        acp.chat_id IS NULL
        OR acp.status IN ('received', 'routed')
      )
  `;

  const result = await client.query(query, [agentName]);
  return result.rows[0]?.cnt ?? 0;
}

/** Collapse whitespace and trim; add ellipsis if truncated. */
export function truncatePreview(message: string, maxLen = 80): string {
  const normalized = message.replace(/\s+/g, " ").trim();
  if (normalized.length <= maxLen) {
    return normalized;
  }
  return normalized.slice(0, maxLen - 1) + "…";
}

/** Group messages by sender, preserving oldest-first order within groups. */
export function groupBySender(
  messages: UnresolvedMessage[],
): Map<string, UnresolvedMessage[]> {
  const groups = new Map<string, UnresolvedMessage[]>();
  for (const msg of messages) {
    const sender = msg.sender.toLowerCase();
    const list = groups.get(sender);
    if (list) {
      list.push(msg);
    } else {
      groups.set(sender, [msg]);
    }
  }
  return groups;
}

/** Escape a single-quote in an agent name for safe SQL literal construction. */
function sqlEscape(value: string): string {
  return value.replace(/'/g, "''");
}

/** Build the paging SELECT that returns rows beyond the 20-message cap. */
export function buildPagingQuery(agentName: string): string {
  const escaped = sqlEscape(agentName);
  return `
SELECT ac.id, ac.sender, ac.message, ac."timestamp"
FROM agent_chat ac
LEFT JOIN agent_chat_processed acp
  ON ac.id = acp.chat_id AND LOWER(acp.agent) = LOWER('${escaped}')
WHERE (
    LOWER('${escaped}') = ANY(SELECT LOWER(unnest(ac.recipients)))
    OR '*' = ANY(ac.recipients)
  )
  AND (
    acp.chat_id IS NULL
    OR acp.status IN ('received', 'routed')
  )
ORDER BY ac."timestamp" ASC
OFFSET ${DIGEST_CAP};
`.trim();
}

/** Result of checking that the runtime functions required for digest delivery exist. */
export type DigestDeliveryCheck =
  | { ok: true }
  | { ok: false; error: string; missing: string[] };

/**
 * Feature-detect the runtime functions the digest uses to deliver itself.
 * The same functions are marked deprecated on newer gateway builds, so we
 * check at runtime rather than relying on the bundled SDK types.
 */
export function checkDigestDeliveryFunctions(
  runtime: PluginRuntime,
): DigestDeliveryCheck {
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
      error: `digest delivery functions not available: ${missing.join(", ")}`,
      missing,
    };
  }

  return { ok: true };
}

/** Build the human-readable digest text from unresolved messages. */
export function buildDigestText(options: {
  agentName: string;
  messages: UnresolvedMessage[];
  totalUnresolved: number;
}): string {
  const { agentName, messages, totalUnresolved } = options;
  const lines: string[] = [];

  lines.push(`Unresolved agent_chat messages for ${agentName}:`);
  lines.push("");

  const groups = groupBySender(messages);
  for (const [sender, msgs] of groups) {
    lines.push(`From ${sender}:`);
    for (const msg of msgs) {
      const ts = new Date(msg.timestamp).toISOString();
      const preview = truncatePreview(msg.message);
      const replyHint = msg.reply_to ? ` [reply to #${msg.reply_to}]` : "";
      lines.push(`  #${msg.id} (${ts}) ${preview}${replyHint}`);
    }
    lines.push("");
  }

  lines.push("How to triage:");
  lines.push(
    "- Reply: use send_agent_message(sender, message, recipients, p_reply_to => <id>)",
  );
  lines.push("- Mark handled: SELECT mark_agent_chat_status(ARRAY[<id>], 'handled');");
  lines.push("- Mark expired: SELECT mark_agent_chat_status(ARRAY[<id>], 'expired');");
  lines.push(
    "- Keep statuses current during normal operation so digests stay small.",
  );
  lines.push("");

  const remaining = totalUnresolved - messages.length;
  if (remaining > 0) {
    lines.push(`${remaining} remaining`);
    lines.push("Paging query:");
    lines.push("```sql");
    lines.push(buildPagingQuery(agentName));
    lines.push("```");
  }

  return lines.join("\n").trim();
}

/** Deliver the digest to the agent via the same reply dispatch path used for inbound messages. */
export async function deliverDigest(options: {
  runtime: PluginRuntime;
  cfg: OpenClawConfig;
  agentName: string;
  digestText: string;
  log?: {
    error?: (m: string) => void;
    info?: (m: string) => void;
    debug?: (m: string) => void;
  };
}): Promise<void> {
  const { runtime, cfg, agentName, digestText, log } = options;

  const check = checkDigestDeliveryFunctions(runtime);
  if (!check.ok) {
    log?.error?.(`agent_chat digest delivery unavailable: ${check.error}`);
    return;
  }

  const replyApi = runtime.channel!.reply;
  const sessionLabel = `agent:${agentName}:agent_chat`;
  const agentChatTo = `agent_chat:${agentName}`;

  const ctxPayload = replyApi.finalizeInboundContext({
    Body: digestText,
    RawBody: digestText,
    CommandBody: digestText,
    From: "agent_chat",
    To: agentChatTo,
    SessionKey: sessionLabel,
    ChatType: "direct",
    ConversationLabel: "agent_chat",
    SenderName: "agent_chat",
    SenderId: "agent_chat",
    Provider: "agent_chat",
    Surface: "agent_chat",
    MessageSid: `digest-${Date.now()}`,
    Timestamp: Date.now(),
    OriginatingChannel: "agent_chat",
    OriginatingTo: agentChatTo,
  });

  const { dispatcher, replyOptions } = replyApi.createReplyDispatcherWithTyping({
    deliver: async () => {
      // The digest itself is not expecting a deliver() reply; the agent is
      // instructed to use send_agent_message / mark_agent_chat_status.
    },
    onError: (err, info) => {
      log?.error?.(`agent_chat digest reply failed: ${err}`);
    },
  });

  try {
    await replyApi.dispatchReplyFromConfig({
      ctx: ctxPayload,
      cfg,
      dispatcher,
      replyOptions,
    });
    log?.info?.(`agent_chat digest delivered to ${agentName}`);
  } catch (err) {
    log?.error?.(`agent_chat digest dispatch failed: ${err}`);
  }
}

/** Track which runtime objects have already fired a digest this generation. */
const firedByRuntime = new WeakMap<object, boolean>();

/** Options for creating the startup digest service. */
export interface StartupDigestServiceOptions {
  runtime: PluginRuntime;
  resolveAgentName: () => string;
  createClient: () => pg.Client;
}

/**
 * Create the startup digest plugin service.
 *
 * Fires once per plugin generation. The guard is keyed on the runtime object
 * so that duplicate service registrations left behind by an old-build hot
 * reload cannot deliver the digest twice, while still allowing a genuine
 * reload (with a fresh runtime or after stop()) to fire again.
 */
export function createStartupDigestService(
  options: StartupDigestServiceOptions,
): OpenClawPluginService {
  const { runtime, resolveAgentName, createClient } = options;
  let fired = false;

  return {
    id: "agent_chat_startup_digest",
    async start(ctx: OpenClawPluginServiceContext) {
      if (fired) {
        ctx.logger.debug?.("agent_chat startup digest already fired for this service instance");
        return;
      }
      if (firedByRuntime.get(runtime)) {
        ctx.logger.debug?.("agent_chat startup digest already fired for this runtime");
        return;
      }
      firedByRuntime.set(runtime, true);
      fired = true;

      const agentName = resolveAgentName();
      if (!agentName) {
        ctx.logger.error?.(
          "agent_chat: cannot run startup digest — no agent name could be resolved from pgConfig.user",
        );
        return;
      }

      const deliveryCheck = checkDigestDeliveryFunctions(runtime);
      if (!deliveryCheck.ok) {
        ctx.logger.error?.(`agent_chat: ${deliveryCheck.error}`);
        return;
      }

      const client = createClient();
      try {
        await client.connect();
        const total = await countUnresolvedMessages(client, agentName);
        if (total === 0) {
          ctx.logger.debug?.("agent_chat: no unresolved messages; skipping digest");
          return;
        }

        const messages = await fetchUnresolvedMessages(client, agentName, DIGEST_CAP);
        const digestText = buildDigestText({ agentName, messages, totalUnresolved: total });
        await deliverDigest({ runtime, cfg: ctx.config, agentName, digestText, log: ctx.logger });
      } catch (err) {
        ctx.logger.error?.(`agent_chat startup digest failed: ${err}`);
      } finally {
        await client.end().catch(() => {});
      }
    },
    async stop(ctx: OpenClawPluginServiceContext) {
      fired = false;
      firedByRuntime.delete(runtime);
      ctx.logger.debug?.("agent_chat startup digest guard reset by stop()");
    },
  };
}
