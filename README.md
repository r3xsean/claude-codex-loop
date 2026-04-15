# claude-codex-loop

**Karpathy-inspired coding principles + OpenAI Codex as a woven-in second-model consultant for Claude Code.**

> ⚠️ **Windows + PowerShell only.** The `/codex` and `/codex-review` skills ship as PowerShell scripts. macOS/Linux users will need to port the scripts to bash/zsh manually — contributions welcome, but cross-platform support is not promised.

---

## What this is — and is not

This is a **coupled system**, not a drop-in prompt preset. It combines:

- A `CLAUDE.md` behavioral spec (Karpathy's four coding principles + a "Production-Ready Loop" for autonomous execution)
- Two Claude Code skills (`/codex`, `/codex-review`) that invoke OpenAI Codex as a second model
- PowerShell helper scripts that wrap the Codex CLI

The principles reference the skills. The skills reference the scripts. The scripts shell out to `codex` (OpenAI's CLI). If you install only the `CLAUDE.md` without the rest, you'll get dangling cross-references. Install all three layers, or rewrite the Codex call-outs in Principles 1 and 4.

**What you need before installing:**
- [Claude Code](https://claude.com/claude-code)
- [OpenAI Codex CLI](https://github.com/openai/codex) authenticated with a plan that includes `gpt-5.4` (the ChatGPT Plus plan is sufficient for typical usage)
- Windows 10/11 with PowerShell 7+ (`pwsh`)

## The idea

### Two Karpathy observations in tension

Karpathy's first observation is about LLM failure modes:

> *"The models make wrong assumptions on your behalf and just run along with them without checking. They don't manage their confusion, don't seek clarifications, don't surface inconsistencies, don't present tradeoffs, don't push back when they should. They really like to overcomplicate code and APIs, bloat abstractions, don't clean up dead code. They still sometimes change/remove comments and code they don't sufficiently understand as side effects, even if orthogonal to the task."*

His second is about what LLMs are exceptionally good at:

> *"LLMs are exceptionally good at looping until they meet specific goals... Don't tell it what to do, give it success criteria and watch it go."*

These pull in opposite directions. The first says: **slow down, surface uncertainty, don't assume.** The second says: **give it criteria, let it run, stop interrupting.** The workflow that gets both right has to distinguish *when* to pause versus *when* to loop — and provide a mechanism to keep the loop alive when friction hits, without handing control back to you every time.

This repo stitches both into one workflow using three ingredients:

### 1. Four Karpathy principles (what to do)

Drawn from [forrestchang/andrej-karpathy-skills](https://github.com/forrestchang/andrej-karpathy-skills). Each addresses a specific failure mode Karpathy named:

- **Think Before Coding** — state assumptions explicitly, present multiple interpretations instead of picking silently, push back when a simpler approach exists. Fights the "wrong assumptions run silently" failure.
- **Simplicity First** — minimum code that solves the problem. No abstractions for single-use code, no configurability that wasn't asked for, no error handling for impossible scenarios. Fights "bloat and overcomplication."
- **Surgical Changes** — touch only what the request requires. Don't "improve" adjacent code, don't refactor things that aren't broken, match existing style. Fights "drive-by edits and orthogonal side effects."
- **Goal-Driven Execution** — transform imperative tasks into verifiable goals ("add validation" → "write tests for invalid inputs, then make them pass"). Strong success criteria let the model loop; weak ones ("make it work") require constant clarification.

### 2. The Production-Ready Loop (when to go fully autonomous)

Karpathy's looping insight only works if the model is actually allowed to loop. By default, Claude Code tends to check in between steps — which is often *correct* behavior, but becomes friction once you've scoped the work and just want it done.

This repo adds a **trigger-phrase mode.** When you say *"production ready"*, *"ship it"*, *"loop until done"*, *"don't stop"*, or equivalent, Claude engages autonomous mode and runs:

```
implement → tests/typecheck/lint → fix failures → /codex-review → fix findings → re-verify → repeat
```

…until the success criteria are met. The loop is **sticky** — once engaged, it continues until a stop condition fires.

There's also a **softer default mode** (no trigger phrase needed): push through obvious next steps without unnecessary check-ins. If the next step is determined by what just happened, take it. This addresses the common complaint of "Claude stops between every step to ask me" without committing you to full autonomy.

### 3. OpenAI Codex as the woven-in second model

Claude is strong, but it makes **correlated errors** — bugs and misreadings it systematically misses because of how it was trained. A second model trained differently catches what the first misses. This repo wires OpenAI Codex (GPT-5.4) into Claude's workflow at two distinct moments, with two distinct roles:

#### `/codex` = navigator — *"Are we taking the right route?"*

Fires **before Claude commits to a direction.** Specifically:

- **Design-presentation moments (primary trigger).** Before Claude presents a non-trivial plan, architecture, data model, or approach comparison, `/codex` runs first. You see a design that has already survived a second opinion — not a raw first draft you then have to ask Claude to validate. Claude folds Codex's feedback into the presentation under an **"integrate judgment, preserve dissent"** rule: agreements are noted, disagreements are surfaced plainly (*"Codex pushed back on X; I adjusted"* / *"Codex still disagrees on Z; my recommendation is A because..."*), and if the plan changed materially, Claude shows the delta (*"My initial instinct was X; after consulting Codex I'm proposing Y because..."*).
- **Commitment-time fallback.** If you commit without an explicit design having been presented ("just go do X"), Codex still runs before code gets written.
- **Mid-loop unblocker.** The most important use. When the Production-Ready Loop hits friction — failed tactics, inconsistent tests, ambiguous review findings, stuck approaches — Codex is consulted *first*, before the loop escalates to interrupting you.

Firing is based on **decision density**, not document shape: multiple coordinated steps or non-obvious tradeoffs fire it; single mechanical steps don't.

#### `/codex-review` = inspector — *"Does the finished work hold up?"*

Fires **before Claude declares victory.** Adversarial completion review with one job: try to break the code. Not a linter, not a style pass. Hunts specifically for the failure modes AI coding agents produce:

- False completion claims ("it's wired up" when it isn't)
- Silent assumptions not surfaced in any spec or comment
- Race conditions and async edge cases
- Incomplete wiring, dead code, leftover stubs
- Production failure modes masked by "works locally"

Returns a verdict (APPROVED / REVISE) plus findings at CRITICAL / HIGH / MEDIUM severity. Auto-invokes before Claude reports a finished non-trivial change. One review per meaningful unit of work, not per file-edit.

#### The role separation in one line

**Use `/codex` before you commit; use `/codex-review` before you declare victory.** One challenges the plan; the other challenges the finished work. They operate on different artifacts at different moments — no collision.

### 4. The escalation ladder (self → /codex → user)

This is what keeps the autonomous loop alive longer than a naive "loop until you hit an error" would.

When Claude hits friction mid-loop, the escalation order is:

1. **Self** — try a different tactic (bounded: no more than 2 retries of the same approach)
2. **`/codex`** — consult Codex for a fresh diagnostic, try its suggested alternative
3. **User** — only as a last resort, with full diagnostic attached

Concretely: same tactic fails twice → Codex gets called for a fresh angle. Tests fail inconsistently → Codex classifies real-bug-vs-flaky. A `/codex-review` finding is ambiguous about whether it's blocking → a fresh Codex session adjudicates. Only after Codex has been consulted and the loop is still stuck does Claude actually interrupt you.

**Hard stops that skip the ladder and go straight to the user:**
- Destructive or irreversible actions (migrations, force-pushes, etc.) — non-negotiable safety gate
- Genuine requirement ambiguity — what you *want* isn't a technical question; Codex can't answer it
- The loop is chasing polish, not substance — `/codex-review` nits don't keep the loop alive; only correctness, regressions, unmet requirements, or missing verification do

### Why the combination matters

Any of the three ingredients alone is useful but incomplete:

- **Principles without the loop**: careful but slow, and you still have to micromanage.
- **The loop without Codex**: fast but brittle — the moment it hits real friction, it either thrashes or interrupts you.
- **Codex without the loop**: a better first draft, but you're still the bottleneck on every subsequent step.

Put together: the principles make Claude's default output better, the loop runs it through a verification cycle autonomously, and Codex both front-loads the plan with a second opinion *and* serves as the first escalation layer when the loop hits friction. The result is a workflow where Claude loops longer on real work before tapping you on the shoulder — and when it does tap, the problem is genuinely a human decision, not something a second model could have resolved.

## Install (manual — canonical)

Everything lives under `~/.claude/`. From a PowerShell prompt:

```powershell
# 1. Clone this repo somewhere (or download the zip)
git clone https://github.com/<your-username>/claude-codex-loop.git
cd claude-codex-loop

# 2. Copy the skills
New-Item -ItemType Directory -Force -Path "$env:USERPROFILE\.claude\skills\codex" | Out-Null
New-Item -ItemType Directory -Force -Path "$env:USERPROFILE\.claude\skills\codex-review" | Out-Null
Copy-Item skills\codex\SKILL.md "$env:USERPROFILE\.claude\skills\codex\SKILL.md"
Copy-Item skills\codex-review\SKILL.md "$env:USERPROFILE\.claude\skills\codex-review\SKILL.md"

# 3. Copy the scripts
New-Item -ItemType Directory -Force -Path "$env:USERPROFILE\.claude\scripts" | Out-Null
Copy-Item scripts\* "$env:USERPROFILE\.claude\scripts\"

# 4. Merge CLAUDE.md into your global config
# - NEW file: copy as-is
Copy-Item CLAUDE.md "$env:USERPROFILE\.claude\CLAUDE.md"
# - APPEND to existing: manually paste sections into your current ~/.claude/CLAUDE.md
```

**If you already have a `~/.claude/CLAUDE.md`**, don't overwrite it — open both files and paste the sections (`Coding Principles`, `Clarifying Questions`, `Codex Consultation`) into your existing file. The principles are designed to sit alongside your existing environment/shell/preference rules.

### Verify the install

```powershell
# Check Codex CLI is on PATH and auth works
codex --version

# Dry-run the skill from Claude Code
# In a Claude Code session, type:
#   /codex hello from a fresh install
# You should see a separate watcher window pop up and Codex respond.
```

If the watcher window doesn't appear, check that `pwsh` (PowerShell 7+) is on your PATH — the script spawns the watcher via `Start-Process pwsh`.

## Install (plugin — optional, not yet supported)

Plugin install via Claude Code's `/plugin` system is not currently packaged. Manual install covers everything the plugin would. If there's demand, open an issue.

## Usage

Once installed, the behavior is automatic per the `CLAUDE.md` spec:

- When Claude is about to present a non-trivial design, it auto-invokes `/codex` first and folds the result into the presentation.
- When Claude finishes a non-trivial implementation, it auto-invokes `/codex-review` before reporting done.
- When you say *"production ready"* / *"ship it"* / *"don't stop"*, Claude engages the autonomous loop and only stops on hard-stop conditions (destructive actions, genuine requirement ambiguity, or after exhausting Codex as an escalation layer).

You can also invoke the skills manually:
- `/codex <question>` — ad-hoc second opinion on anything
- `/codex-review` — review uncommitted changes (or pass specific files/scope as args)

Each Codex call spawns a separate PowerShell window that live-tails the session (commands, reasoning, output). The window auto-closes 5 minutes after Codex finishes, or you can dismiss it. Pass `-NoWatch` to the underlying script if you want to suppress the window.

## Tested environment

- **Claude Code**: tested around April 2026 (Opus 4.6). Skill and hook conventions may drift over time.
- **PowerShell**: 7.x (`pwsh`). Windows PowerShell 5.1 is not tested.
- **OpenAI Codex CLI**: current version at time of writing. Uses `codex exec --json` with event-stream parsing.
- **OS**: Windows 10/11.

If Claude Code's plugin/skill format changes meaningfully after April 2026, this repo may need updates.

## Known non-goals

- **Cross-platform support.** The scripts are PowerShell-only. Porting to bash/zsh is straightforward for anyone comfortable with shell, but not maintained in this repo.
- **Non-Claude-Code harnesses.** The `CLAUDE.md` spec assumes Claude Code's tool vocabulary (AskUserQuestion, task tools, etc.).
- **OpenAI model routing.** The scripts hardcode `gpt-5.4` as the default. Override with `-Model <name>` on the script if you want something else.
- **Claiming this is a silver bullet.** These are guidelines that bias toward caution over speed. For trivial work they add friction. They're designed for non-trivial coding sessions where wrong assumptions cost more than a Codex call does.

## Credits

- **[forrestchang/andrej-karpathy-skills](https://github.com/forrestchang/andrej-karpathy-skills)** — the Karpathy-principles `CLAUDE.md` this repo builds on. Four-principle framing, section structure, and much of the wording of Principles 2-4 are derived directly from forrestchang's work.
- **[Andrej Karpathy's post](https://x.com/karpathy/status/2015883857489522876)** — the observations about LLM coding failure modes that motivate the principles.
- **OpenAI Codex** — the second-model consultant that makes the navigator/inspector split possible.

## License

[MIT](./LICENSE)
