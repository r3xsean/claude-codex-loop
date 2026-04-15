---
name: codex
description: Get a second-model perspective from OpenAI Codex (GPT-5.4) on decisions, approaches, design choices, debugging, or explanations. Supports multi-turn conversations — resumes the prior session automatically when called again in the same CC conversation. **Use this proactively, not just as an escape hatch — it's an ambient decision consultant.** TRIGGER when (1) the user explicitly asks for "codex", "second opinion", "what does gpt think", "ask another model"; (2) discussing WHICH approach to take — X vs Y, library picks, tech stack, ORM choice, refactor direction, scope decisions (one PR vs split) — these are the highest-value calls; (3) design decisions — data modeling, API shape, state machines, file layout, naming conventions at scale; (4) architectural decisions with downstream consequences; (5) commitment moments — when the user says "okay let's do X" on a non-obvious decision, auto-invoke BEFORE writing code to validate the approach; (6) stuck after 2-3 attempts on a bug; (7) stress-testing a hypothesis before acting on it; (8) "am I overthinking / underthinking this?" self-checks when confidence feels off. Do NOT trigger for trivial implementation, pure syntax/API lookups, or things Claude knows cold. Budget is not a constraint — prefer calling it when in doubt.
argument-hint: "<prompt>"
---

# Codex General Purpose

Forward a prompt to OpenAI Codex CLI (GPT-5.4) for a second model's perspective on debugging, planning, architecture, explanation, or ad-hoc questions.

**Multi-turn support:** Codex sessions can be resumed. Each run prints a `SESSION_ID: <uuid>` trailer. If you ran `/codex` earlier in this conversation, you have that UUID in your context — use it with `-Resume` to continue the prior session instead of starting fresh.

## How it works

The helper script `~/.claude/scripts/codex-run.ps1` handles everything — CLI mechanics, preamble injection, session ID capture, error handling. You just:

1. Decide fresh vs resume (based on whether a prior SESSION_ID exists in your context)
2. Compose a rich prompt (briefing + user question)
3. Pipe it to the script via a backgrounded PowerShell tool call
4. When the task completes, Read the task's output file
5. Triage and present

**Backgrounded for safety** — Codex calls can take 5-10+ minutes and synchronous PowerShell tool calls have a 10-minute cap. Background mode has no timeout. The script prints the full response + SESSION_ID to stdout, which becomes the task's captured output file — Claude Reads that file once the task completes.

## Proactive use — when to reach for Codex without being asked

**Codex is an ambient decision consultant, not an emergency escape hatch.** The highest-value calls happen when you (Claude) are confident enough to answer but the decision has downstream consequences — that's the exact moment where correlated errors between two models can be broken.

Treat Codex as "in the back of your mind" during any conversation that involves a decision:

**Discussion phase** — user is exploring options, weighing tradeoffs, asking "should I X or Y":
- **Offer once per decision thread** — end your substantive answer with a one-line prompt: *"Want a second read from Codex on this before we commit?"*
- Do NOT auto-invoke during open exploration — let the user drive
- Do NOT ask repeatedly in the same thread — if they said no, respect it

**Commitment phase** — user has decided to act ("okay let's do X", "yeah let's go with that approach", "implement it"):
- **Auto-invoke `/codex`** BEFORE writing code, when the decision is non-obvious or has downstream consequences
- Don't ask permission — just run it. The user already told you the window popping up is fine.
- Prompt Codex with: what the user is about to do, why, the alternatives considered, and ask "is this the right call, or am I missing something?"
- Do NOT auto-invoke for trivial or well-understood implementations

**Confidence/stakes mismatch** — you notice the stakes are high but your confidence is also high:
- That's the danger zone for correlated errors. Auto-invoke to stress-test.
- Examples: writing auth code, data migrations, anything touching production state, anything where "works locally" is a weak signal

**"Am I framing this right?" moments:**
- User's question feels too clean or too easy → maybe a framing assumption is wrong → consult Codex
- You're about to give a strong recommendation → auto-invoke to validate
- You catch yourself about to write a lot of code fast → pause, consult first

**When to SKIP Codex (not everything needs a second opinion):**
- Trivial implementation (typos, formatting, renames, obvious bugs)
- Pure syntax or API lookups ("how do I write a Python list comprehension")
- Things you genuinely know cold and the user would be annoyed by the delay
- Mid-implementation debugging where Codex has no more information than you

**Budget is not a constraint.** The Plus plan has plenty for the user's usage pattern. The watcher window popping up is fine. Prefer calling Codex when in doubt.

## Step 1: Validate and decide fresh vs resume

`$ARGUMENTS` is required. If empty, ask the user what they want to send to Codex.

**RESUME** (default when possible): If you ran `/codex` earlier in this conversation AND the new question is a follow-up, continuation, or related topic, resume the prior session. You'll have the previous `SESSION_ID: <uuid>` in your context from the prior tool output. Pass it to `-Resume`.

**FRESH**: Start a new session if (a) this is the first `/codex` call in the conversation, (b) the new question is about a completely unrelated topic, or (c) the user explicitly asks to "start fresh" / "new conversation" / similar.

When in doubt, prefer resume — users generally want continuity.

## Step 2: Compose the prompt

**You do NOT need to write a rules preamble or CLAUDE.md instruction** — the script automatically prepends `~/.claude/scripts/codex-common-preamble.txt` on fresh runs. It contains the CRITICAL RULES (read-only) and instructions to read both project and global CLAUDE.md. Don't duplicate.

### Always include — every call, fresh or resume

Regardless of fresh vs resume, two things ALWAYS go in the prompt so Codex knows EXACTLY what the user wants:

- **Verbatim user constraints** — quote any hard requirements the user stated word-for-word. Do not paraphrase. If the user said "must work on Windows PowerShell, no bash", quote that exactly. Same for negative constraints ("don't refactor unrelated code", "no new dependencies", "don't touch X").
- **Exact user wording for the current ask** — paste the user's actual question or instruction verbatim, not your interpretation of it. Codex needs to see what the user said, not what Claude understood.

This applies even on resume — the user may have shifted direction, added a constraint, or phrased the new ask in a way that matters. Never assume Codex can infer the current ask from prior turns. Quoting verbatim is cheap insurance against Claude's paraphrase silently dropping a load-bearing word.

### FRESH session — generous context briefing

Codex starts with ZERO context. Brief it like a smart colleague who just walked into the room:

- **The user's actual goal** — the real thing they're trying to accomplish
- **Files already read this session** — list by absolute path and tell Codex to read them. Codex has filesystem access; point it at paths instead of pasting contents inline.
- **What's already been tried** — approaches, errors verbatim, hypotheses ruled out
- **Current hypothesis** — what you currently believe
- **Constraints and environment** — framework versions, platform quirks
- **Relevant error traces** — verbatim if load-bearing
- **Project-specific conventions** — anything unusual about the codebase
- **The user's actual question** — woven in naturally

Err on the side of MORE context. A 2000-token briefing producing a good answer beats a 50-token prompt producing a generic one.

### RESUMED session — delta only

Codex already remembers everything from turn 1. Send ONLY what's NEW:

- What happened between turns (what you and the user discussed/discovered)
- New files or errors not yet seen by Codex
- Updated hypothesis
- The follow-up question

Do NOT repeat the goal, files already listed, errors Codex already saw, or the preamble (none of that is auto-injected on resume).

A good resume prompt is often 5-10x shorter than the original fresh prompt.

## Step 3: Invoke the script (backgrounded)

**Variant A — FRESH session:**

```powershell
@'
<Claude: replace this with the full composed prompt — briefing + user question>
'@ | & "$env:USERPROFILE\.claude\scripts\codex-run.ps1" -Mode codex
```

**Variant B — RESUME prior session:**

```powershell
@'
<Claude: replace this with the delta-only follow-up content>
'@ | & "$env:USERPROFILE\.claude\scripts\codex-run.ps1" -Mode codex -Resume "<SESSION_UUID>"
```

Both commands automatically spawn the live watcher window. The user will see commands, output, and the final answer stream in a separate PowerShell window as Codex runs. Append `-NoWatch` only if the user explicitly wants to suppress the window.

**Critical — use single-quoted here-strings (`@'...'@`)**, NOT double-quoted. Single-quoted is parser-safe against `${`, `$(`, backticks, and template placeholders that would crash a double-quoted here-string. The closing `'@` MUST be at column 0 (no leading whitespace).

**Run with `run_in_background: true`.** Backgrounding has no timeout cap, which is critical for Codex calls that may take several minutes. When the task completes you'll receive a notification with the task's output file path.

**Do NOT send a preamble message announcing the call.** No "Asking Codex — this may take a minute", no "Continuing Codex conversation", no "let me consult Codex". Invoke the PowerShell tool directly with no accompanying text. The watcher window pops up immediately and the user already knows the call is in flight — a verbal announcement just wastes a turn. Save all your text output for the triage in Step 5.

## Step 4: Read the response

When the task completion notification arrives, **immediately use the Read tool** on the task's output file (the path is in the `<output-file>` tag of the notification). It contains:

```
OUTFILE: $env:TEMP\codex-<timestamp>.txt

<Codex's response>

---
SESSION_ID: <uuid>
```

Three possible cases:

1. **Normal case**: Read gives you the full response. Use it. Remember the SESSION_ID for potential resume later.
2. **Truncation**: if the task output file is too large and the Read gets cut off, the `OUTFILE:` header at the very top points to a persistent copy of the full response. Read that path instead.
3. **Codex error**: if Codex failed (rate limit, crash), the output will start with `CODEX ERROR` followed by stderr. Surface it to the user.

## Step 5: Triage (do NOT regurgitate)

**The user already saw Codex's full response live in the watcher window.** Do NOT paste it back verbatim or restate Codex's points in your own words — that's just noise. Your value is the triage pass, not the relay.

Jump straight into your own perspective:

- Where do you agree with Codex? (Be specific — cite a claim, don't just say "I agree")
- Where do you disagree, and why? (Show the line of code or fact that disproves Codex)
- Any context Codex missed that you know from the current session? (This is the highest-value part — things Codex couldn't see because it didn't live through your session)
- If Codex gave actionable suggestions, say which you'd act on and which you'd skip

Keep it short and opinionated. The user wanted a second model's take PLUS your synthesis — they don't need a transcript, they need judgment. If Codex's answer was simply correct and you have nothing to add, say "Codex's answer looks right to me" in one line and stop.

The only exception: if `-NoWatch` was passed (user suppressed the window), they did NOT see the response live — in that case, summarize the key points briefly before your triage so they have context.

## Script flags reference

`~/.claude/scripts/codex-run.ps1`:

- `-Mode codex|review` — auto-resolves preamble/postamble/ephemeral per skill
- `-Resume <uuid>` — resume a prior session (omit for fresh)
- `-PromptFile <path>` — alternative to stdin pipe (rare; use pipe)
- `-OutFile <path>` — custom persistent output path (script auto-generates if omitted)
- `-Ephemeral` — don't persist session (review mode sets this automatically)
- `-Model <model>` — override model (default: `gpt-5.4`)
- `-KeepPromptFile` — don't delete `-PromptFile` after run (debug only)
- `-NoWatch` — suppress the live watcher window. By default, every run spawns a separate PowerShell window that live-tails Codex's event stream (commands, output, final answer). Auto-closes 5 minutes after Codex finishes, or the user can dismiss it manually. Pass `-NoWatch` only when the user explicitly asks to "not show the window", "hide the watcher", "run quietly", or similar.

The script always writes a persistent output file at `OUTFILE:` (auto-generated in TEMP unless `-OutFile` is passed). It's never auto-deleted — that's what makes the truncation fallback work. Temp accumulation is fine; Windows temp cleanup handles it.

## Notes

- Codex runs with `--dangerously-bypass-approvals-and-sandbox` so it can read project files on Windows. Read-only behavior is enforced by the preamble.
- Session files live at `~/.codex/sessions/YYYY/MM/DD/rollout-<timestamp>-<UUID>.jsonl`. Managed by Codex itself — no cleanup needed.
- Budget: each invocation uses Plus plan credits. Resuming is cheaper than fresh.
