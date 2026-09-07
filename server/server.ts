// agentd.ts — minimal agent service.
//   npm i @anthropic-ai/claude-agent-sdk && npm i -D @types/node tsx
//   npx tsx agentd.ts
import {
  query,
  type SDKUserMessage,
  type SDKResultMessage,
  type Query,
  type PermissionMode,
  type TerminalReason,
} from "@anthropic-ai/claude-agent-sdk";
import http from "node:http";
import { randomUUID } from "node:crypto";

const PORT = 4747;
const startedAt = Date.now();

/** Every permission mode the agent SDK supports.
 *   default          — ask (via canUseTool) for anything not pre-approved
 *   acceptEdits      — auto-accept file edits, still ask for the rest
 *   bypassPermissions— never ask, allow everything
 *   plan             — read-only; the agent proposes a plan via ExitPlanMode
 *   dontAsk          — never ask, deny anything not pre-approved
 *   auto             — a model classifier answers the prompts
 */
const MODES = ["default", "acceptEdits", "bypassPermissions", "plan", "dontAsk", "auto"] as const;
const isMode = (m: unknown): m is PermissionMode =>
  typeof m === "string" && (MODES as readonly string[]).includes(m);

/** Queue states are ours — the SDK has no task queue, and a task isn't running
 *  until we hand its prompt to the agent. Terminal states are the SDK result
 *  subtype verbatim, so we don't invent a vocabulary on top of it. */
type TaskState =
  | "queued" | "running" | "waiting_input"
  | SDKResultMessage["subtype"];

type Task = {
  id: string;
  session: string;
  prompt: string;
  requestedMode?: PermissionMode;  // set only when the caller named one
  mode?: PermissionMode;           // what it is actually running under
  state: TaskState;
  result?: string;              // final assistant text, or the error text
  isError?: boolean;            // a "success" turn can still carry an API error
  terminalReason?: TerminalReason;  // why the turn stopped, per the SDK
  interrupted?: boolean;        // we asked for it to stop
  createdAt: number;
};

type Request = {
  id: string;
  taskId: string;
  session: string;
  tool: string;
  input: unknown;
  state: "pending" | "answered";
};

const tasks = new Map<string, Task>();
const requests = new Map<string, Request>();
const resolvers = new Map<string, (allow: boolean) => void>();
const sessions = new Map<string, Session>();

/** Async queue: the agent awaits it, HTTP handlers push onto it. */
class Inbox {
  private items: SDKUserMessage[] = [];
  private waiters: ((m: SDKUserMessage) => void)[] = [];
  push(text: string) {
    const msg: SDKUserMessage = {
      type: "user",
      message: { role: "user", content: text },
      parent_tool_use_id: null,
      session_id: "",
    };
    const w = this.waiters.shift();
    if (w) w(msg); else this.items.push(msg);
  }
  async *stream(): AsyncGenerator<SDKUserMessage> {
    while (true) {
      const next = this.items.shift();
      yield next ?? (await new Promise<SDKUserMessage>((r) => this.waiters.push(r)));
    }
  }
}

class Session {
  inbox = new Inbox();
  q?: Query;
  sessionId?: string;
  /** Tasks sent but not yet resolved, oldest first. */
  queue: string[] = [];
  /** The mode currently applied to the live query. */
  mode: PermissionMode;

  constructor(public name: string, public cwd: string, public defaultMode: PermissionMode = "default") {
    this.mode = defaultMode;
  }

  current(): Task | undefined {
    return this.queue.length ? tasks.get(this.queue[0]) : undefined;
  }

  send(prompt: string, mode?: PermissionMode): Task {
    const task: Task = {
      id: randomUUID().slice(0, 8),
      session: this.name,
      prompt,
      requestedMode: mode,
      state: "queued",
      createdAt: Date.now(),
    };
    tasks.set(task.id, task);
    this.queue.push(task.id);
    if (this.queue.length === 1) void this.dispatch();
    return task;
  }

  /** Apply the head task's mode, then hand its prompt to the agent.
   *  The mode is resolved here, not when the task was queued, so a task sitting
   *  in the queue picks up whatever the session default is by the time it runs.
   *  The prompt is only pushed once the mode is in place, so a task never runs
   *  under the previous task's permissions. */
  private async dispatch() {
    const t = this.current();
    if (!t) return;
    t.state = "running";
    t.mode = t.requestedMode ?? this.defaultMode;
    if (t.mode !== this.mode) {
      try {
        await this.q!.setPermissionMode(t.mode);
        this.mode = t.mode;
      } catch (e) {
        // Running under the wrong mode is worse than not running: fail the task.
        console.error(`[${this.name}] could not set mode ${t.mode}:`, e);
        this.finish("error_during_execution", {
          result: `could not set mode ${t.mode}: ${e}`,
          isError: true,
        });
        return;
      }
    }
    console.log(`[${this.name}] task ${t.id} running (mode: ${t.mode})`);
    this.inbox.push(t.prompt);
  }

  finish(state: TaskState, outcome: Partial<Task> = {}) {
    const t = this.current();
    if (!t) return;
    Object.assign(t, outcome, { state });
    // A finished task can't answer its own approval prompts any more.
    for (const r of requests.values()) {
      if (r.taskId === t.id && r.state === "pending") resolvers.get(r.id)?.(false);
    }
    this.queue.shift();
    void this.dispatch();
  }

  /** Stop the running turn. The SDK still emits a result for it, which is what
   *  moves the task out of "running" — we only mark why. */
  async interrupt() {
    const t = this.current();
    if (t) t.interrupted = true;
    await this.q?.interrupt();
  }

  /** Change the mode now — including mid-turn, which is the point: it's how you
   *  stop a running task from asking. Also becomes the default for later tasks
   *  that don't name their own. */
  async setDefaultMode(mode: PermissionMode) {
    this.defaultMode = mode;
    if (mode !== this.mode) {
      await this.q!.setPermissionMode(mode);
      this.mode = mode;
    }
    const t = this.current();
    if (t) t.mode = mode;
  }

  /** Approvals already raised, which a mode change does NOT retroactively answer. */
  pending(): number {
    const t = this.current();
    return t ? [...requests.values()]
      .filter((r) => r.taskId === t.id && r.state === "pending").length : 0;
  }

  async run() {
    this.q = query({
      prompt: this.inbox.stream(),
      options: {
        cwd: this.cwd,
        permissionMode: this.defaultMode,
        // Required by the SDK before `bypassPermissions` may ever be selected.
        allowDangerouslySkipPermissions: true,
        allowedTools: ["Read", "Grep", "Glob"],   // pre-approved, never ask
        settingSources: ["project", "user"],      // pick up CLAUDE.md, .claude/agents
        canUseTool: async (tool, input) => {
          const task = this.current();
          const id = randomUUID().slice(0, 8);
          requests.set(id, {
            id, taskId: task?.id ?? "?", session: this.name,
            tool, input, state: "pending",
          });
          if (task) task.state = "waiting_input";
          console.log(`[${this.name}] needs approval ${id}: ${tool}`);

          const allow = await new Promise<boolean>((resolve) => {
            resolvers.set(id, resolve);
            setTimeout(() => resolvers.has(id) && resolve(false), 600_000);
          });

          resolvers.delete(id);
          requests.get(id)!.state = "answered";
          if (task && task.state === "waiting_input") task.state = "running";
          return allow
            ? { behavior: "allow", updatedInput: input as Record<string, unknown> }
            : { behavior: "deny", message: "Denied by operator" };
        },
      },
    });

    for await (const msg of this.q) {
      if ("session_id" in msg && msg.session_id) this.sessionId = msg.session_id;

      // Exactly one result message per turn — that's the turn-complete signal.
      if (msg.type === "result") {
        this.finish(msg.subtype, {
          result: msg.subtype === "success" ? msg.result : undefined,
          isError: msg.is_error,
          terminalReason: msg.terminal_reason,
        });
        console.log(`[${this.name}] task finished: ${msg.subtype}`);
      }
    }
  }
}

/** A queued task has no mode yet — it resolves one when it dispatches. Report
 *  the mode it would run under right now, so `mode` is never missing. */
const taskView = (t: Task) => ({
  ...t,
  mode: t.mode ?? t.requestedMode ?? sessions.get(t.session)?.defaultMode ?? "default",
});

// ---------- HTTP, loopback only ----------
/** A parse error here used to throw inside the 'end' handler, which is an
 *  uncaught exception — one malformed body took the whole server down. */
class BadBody extends Error {}

function body(req: http.IncomingMessage): Promise<any> {
  return new Promise((resolve, reject) => {
    let b = "";
    req.on("data", (c) => (b += c));
    req.on("end", () => {
      try {
        resolve(b ? JSON.parse(b) : {});
      } catch {
        reject(new BadBody(`body is not valid JSON: ${b.slice(0, 100)}`));
      }
    });
    req.on("error", (e) => reject(e));
  });
}

const server = http.createServer(async (req, res) => {
  const send = (code: number, obj: unknown) => {
    res.writeHead(code, { "content-type": "application/json" });
    res.end(JSON.stringify(obj, null, 2));
  };

  // Loopback-only bind is the boundary; this keeps browsers from reaching it.
  if (req.headers.origin) return send(403, { error: "no browser origins" });

  const url = new URL(req.url!, "http://localhost");
  const parts = url.pathname.split("/").filter(Boolean);

  try {
    // 0. liveness — cheap, touches no session state, so a monitor can poll it
    //    without perturbing anything the agent is doing.
    if (req.method === "GET" && parts[0] === "health" && parts.length === 1) {
      return send(200, {
        ok: true,
        uptimeSeconds: Math.round((Date.now() - startedAt) / 1000),
        sessions: sessions.size,
        tasks: tasks.size,
        pendingApprovals: [...requests.values()].filter((r) => r.state === "pending").length,
      });
    }

    // 1. create a session
    if (req.method === "POST" && parts[0] === "sessions" && parts.length === 1) {
      const { name, cwd, mode } = await body(req);
      if (mode !== undefined && !isMode(mode))
        return send(400, { error: `mode must be one of ${MODES.join(", ")}` });
      const s = new Session(name, cwd ?? process.cwd(), mode);
      sessions.set(name, s);
      s.run().catch((e) => console.error(`[${name}]`, e));
      return send(201, { name, cwd: s.cwd, mode: s.defaultMode });
    }

    // 2. give it a task, optionally in its own permission mode
    if (req.method === "POST" && parts[0] === "sessions" && parts[2] === "tasks") {
      const s = sessions.get(parts[1]);
      if (!s) return send(404, { error: "no such session" });
      const { text, mode } = await body(req);
      if (mode !== undefined && !isMode(mode))
        return send(400, { error: `mode must be one of ${MODES.join(", ")}` });
      return send(202, taskView(s.send(text, mode)));
    }

    // change the session's default mode (applies now if nothing is running)
    if (req.method === "POST" && parts[0] === "sessions" && parts[2] === "mode") {
      const s = sessions.get(parts[1]);
      if (!s) return send(404, { error: "no such session" });
      const { mode } = await body(req);
      if (!isMode(mode)) return send(400, { error: `mode must be one of ${MODES.join(", ")}` });
      await s.setDefaultMode(mode);
      return send(200, {
        name: s.name, mode: s.defaultMode, applied: s.mode,
        // Still blocked on a prompt raised before the switch? Answer it to move on.
        pendingApprovals: s.pending(),
      });
    }

    // cancel the in-flight task
    if (req.method === "POST" && parts[0] === "sessions" && parts[2] === "interrupt") {
      const s = sessions.get(parts[1]);
      if (!s) return send(404, { error: "no such session" });
      await s.interrupt();
      return send(200, { ok: true });
    }

    // 3. status
    if (req.method === "GET" && parts[0] === "tasks") {
      const all = [...tasks.values()].sort((a, b) => a.createdAt - b.createdAt);
      const want = url.searchParams.get("state");
      return send(200, (want ? all.filter((t) => t.state === want) : all).map(taskView));
    }

    if (req.method === "GET" && parts[0] === "requests") {
      return send(200, [...requests.values()].filter((r) => r.state === "pending"));
    }

    if (req.method === "GET" && parts[0] === "sessions") {
      return send(200, [...sessions.values()].map((s) => ({
        name: s.name, cwd: s.cwd, sessionId: s.sessionId,
        mode: s.defaultMode, appliedMode: s.mode,
        current: s.current()?.id ?? null, queued: s.queue.length,
      })));
    }

    // answer a pending approval
    if (req.method === "POST" && parts[0] === "requests" && parts[2] === "answer") {
      const { allow } = await body(req);
      const r = resolvers.get(parts[1]);
      if (!r) return send(404, { error: "no such pending request" });
      r(allow ?? true);
      return send(200, { ok: true });
    }

    send(404, { error: "no route" });
  } catch (e) {
    send(e instanceof BadBody ? 400 : 500, { error: String(e) });
  }
});

server.listen(PORT, "127.0.0.1", () =>
  console.log(`agentd on http://127.0.0.1:${PORT}`));
