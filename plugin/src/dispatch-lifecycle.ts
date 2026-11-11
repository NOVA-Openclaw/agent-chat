/**
 * Compatibility wrapper for the reply-dispatcher lifecycle.
 *
 * Older gateway builds expose only createReplyDispatcherWithTyping() and
 * require the caller to release the dispatcher reservation with
 * dispatcher.markComplete(). Newer builds add withReplyDispatcher(), which
 * settles the dispatcher automatically.
 *
 * This helper detects whichever API is present, passes metadata when the
 * runtime accepts it, and guarantees that markComplete() runs after the turn.
 */

import type { PluginRuntime } from "openclaw/plugin-sdk";

export interface ReplyDispatcherLifecycleOptions<T> {
  runtime: PluginRuntime;
  deliver: (payload: unknown, info: { kind: string }) => Promise<void> | void;
  onError?: (err: unknown, info: { kind: string }) => void;
  metadata?: { sessionKey?: string; runId?: string };
  run: (args: {
    dispatcher: unknown;
    replyOptions: unknown;
    markDispatchIdle: () => void;
  }) => Promise<T>;
}

/**
 * Run plugin work against a reply dispatcher, releasing its reservation in
 * all build variants.
 */
export async function dispatchWithReplyLifecycle<T>(
  options: ReplyDispatcherLifecycleOptions<T>,
): Promise<T> {
  const { runtime, deliver, onError, metadata, run } = options;
  const replyApi = runtime.channel?.reply as Record<string, unknown> | undefined;
  if (!replyApi) {
    throw new Error("runtime.channel.reply is not available");
  }

  const createOptions: Record<string, unknown> = { deliver, onError };
  if (metadata) {
    createOptions.metadata = metadata;
  }

  type CreateFn = (opts: Record<string, unknown>) => {
    dispatcher: { markComplete?: () => void; waitForIdle?: () => Promise<void> };
    replyOptions: unknown;
    markDispatchIdle: () => void;
  };
  const create = replyApi.createReplyDispatcherWithTyping as CreateFn;

  let typingResult: ReturnType<CreateFn>;

  try {
    typingResult = create(createOptions);
  } catch (err) {
    // Some old runtimes reject the unknown `metadata` option. Retry without it.
    if (metadata) {
      typingResult = create({ deliver, onError });
    } else {
      throw err;
    }
  }

  const { dispatcher, replyOptions, markDispatchIdle } = typingResult;

  if (typeof replyApi.withReplyDispatcher === "function") {
    return await (replyApi.withReplyDispatcher as (args: {
      dispatcher: unknown;
      run: () => Promise<T>;
    }) => Promise<T>)({
      dispatcher,
      run: () => run({ dispatcher, replyOptions, markDispatchIdle }),
    });
  }

  try {
    return await run({ dispatcher, replyOptions, markDispatchIdle });
  } finally {
    if (typeof dispatcher.markComplete === "function") {
      dispatcher.markComplete();
    }
    if (typeof dispatcher.waitForIdle === "function") {
      await dispatcher.waitForIdle();
    }
  }
}
