import { Type, type Static } from "@sinclair/typebox";
import type { AnyAgentTool, OpenClawConfig } from "openclaw/plugin-sdk";
import type pg from "pg";
import { resolveAgentName } from "./channel.js";

/**
 * Minimal runtime context passed to plugin tool factories.
 * We define this locally because the installed SDK does not export it from the
 * public plugin-sdk entry point.
 */
export interface AgentChatToolContext {
  config?: OpenClawConfig;
  workspaceDir?: string;
  agentDir?: string;
  agentId?: string;
  sessionKey?: string;
  messageChannel?: string;
  agentAccountId?: string;
  sandboxed?: boolean;
}

const MAX_MESSAGE_BYTES = 64 * 1024;

export const SendParams = Type.Object(
  {
    to: Type.Union([Type.String({ minLength: 1 }), Type.Literal("*")]),
    text: Type.String({ minLength: 1, maxLength: 65535 }),
    replyTo: Type.Optional(
      Type.Integer({ minimum: 1, maximum: 2147483647 }),
    ),
  },
  { additionalProperties: false },
);

export const MarkParams = Type.Object(
  {
    ids: Type.Array(Type.Integer({ minimum: 1, maximum: 2147483647 }), {
      minItems: 1,
      uniqueItems: true,
    }),
    status: Type.Union([Type.Literal("handled"), Type.Literal("skipped")]),
  },
  { additionalProperties: false },
);

export const MuteParams = Type.Object(
  {
    peer: Type.String({ minLength: 1 }),
    minutes: Type.Optional(Type.Integer({ minimum: 1 })),
    reason: Type.Optional(Type.String()),
    unmute: Type.Optional(Type.Boolean()),
  },
  { additionalProperties: false },
);

function textExceedsByteLimit(text: string, limit: number): boolean {
  return Buffer.byteLength(text, "utf8") > limit;
}

function toolResultOk(details: unknown): {
  content: [{ type: "text"; text: string }];
  details: unknown;
} {
  return {
    content: [{ type: "text", text: JSON.stringify(details, null, 2) }],
    details,
  };
}

function toolResultError(message: string): {
  content: [{ type: "text"; text: string }];
  details: { ok: false; error: string };
} {
  return {
    content: [{ type: "text", text: message }],
    details: { ok: false, error: message },
  };
}

export interface AgentChatToolsOptions {
  createClient: () => pg.Client;
  resolveDbUser: () => string;
}

/**
 * Factory for the agent_chat plugin tools.
 *
 * Returns null for sandboxed sessions (subagents) so the tools are only
 * exposed to the main agent sessions, as required by SE #1453 decision D8.
 */
export function createAgentChatTools(
  options: AgentChatToolsOptions,
): (ctx: AgentChatToolContext) => AnyAgentTool[] | null {
  return (toolCtx) => {
    if (toolCtx.sandboxed) {
      return null;
    }

    const dbUser = options.resolveDbUser();
    if (!dbUser) {
      return null;
    }

    const sendTool: AnyAgentTool = {
      name: "agent_chat_send",
      label: "Send agent_chat message",
      description:
        "Send a message to one agent (to: 'agent_name') or all peers (to: '*') over agent_chat. " +
        "The sender is always this agent. Use replyTo to thread an existing message.",
      parameters: SendParams,
      async execute(_toolCallId, params: Static<typeof SendParams>) {
        const text = params.text;
        if (textExceedsByteLimit(text, MAX_MESSAGE_BYTES)) {
          return toolResultError(
            `agent_chat_send: text exceeds ${MAX_MESSAGE_BYTES} bytes`,
          );
        }

        const recipients = params.to === "*" ? ["*"] : [params.to.toLowerCase()];
        const replyTo = params.replyTo ?? null;

        const client = options.createClient();
        try {
          await client.connect();
          const result = await client.query<{ id: number | null }>(
            `SELECT send_agent_message($1::text, $2::text, $3::text[], p_ttl => $4::interval, p_reply_to => $5::integer) AS id`,
            [dbUser, text, recipients, null, replyTo],
          );
          const id = result.rows[0]?.id;
          if (id == null) {
            return toolResultOk({
              suppressed: true,
              reason: "matched agent_chat error-template filter",
            });
          }
          return toolResultOk({ id });
        } finally {
          await client.end().catch(() => {});
        }
      },
    };

    const markTool: AnyAgentTool = {
      name: "agent_chat_mark",
      label: "Mark agent_chat message status",
      description:
        "Mark one or more agent_chat messages as handled or skipped. " +
        "Only messages addressed to this agent (or broadcasts) can be marked.",
      parameters: MarkParams,
      async execute(_toolCallId, params: Static<typeof MarkParams>) {
        const ids = params.ids;
        const status = params.status;

        const client = options.createClient();
        try {
          await client.connect();
          const result = await client.query<{ applied_ids: bigint[] }>(
            `SELECT mark_agent_chat_status($1::bigint[], $2::text) AS applied_ids`,
            [ids, status],
          );
          const applied = (result.rows[0]?.applied_ids ?? []).map((n) => Number(n));
          const appliedSet = new Set(applied);
          const notApplied = ids.filter((id) => !appliedSet.has(id));
          return toolResultOk({ applied, notApplied });
        } finally {
          await client.end().catch(() => {});
        }
      },
    };

    const muteTool: AnyAgentTool = {
      name: "agent_chat_mute",
      label: "Mute or unmute an agent_chat peer",
      description:
        "Pause inbound agent_chat wake turns from a peer for a number of minutes (default 60). " +
        "Set unmute: true to remove the mute early. The peer receives one system notice when muted.",
      parameters: MuteParams,
      async execute(_toolCallId, params: Static<typeof MuteParams>) {
        const peer = params.peer.toLowerCase();
        const client = options.createClient();
        try {
          await client.connect();
          if (params.unmute) {
            const result = await client.query<{ unmuted: boolean }>(
              `SELECT agent_chat_unmute_peer($1::text) AS unmuted`,
              [peer],
            );
            return toolResultOk({ unmuted: result.rows[0]?.unmuted ?? false });
          }

          const minutes = params.minutes ?? null;
          const reason = params.reason ?? null;
          const result = await client.query<{ muted_until: Date }>(
            `SELECT agent_chat_mute_peer($1::text, $2::integer, $3::text) AS muted_until`,
            [peer, minutes, reason],
          );
          const mutedUntil = result.rows[0]?.muted_until;
          return toolResultOk({
            mutedUntil: mutedUntil ? mutedUntil.toISOString() : null,
          });
        } finally {
          await client.end().catch(() => {});
        }
      },
    };

    return [sendTool, markTool, muteTool];
  };
}
