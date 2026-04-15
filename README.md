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

## The idea in one page

Karpathy observed that LLMs:

> *"make wrong assumptions on your behalf and just run along with them without checking. They don't manage their confusion, don't seek clarifications, don't surface inconsistencies, don't present tradeoffs, don't push back when they should. They really like to overcomplicate code and APIs, bloat abstractions, don't clean up dead code..."*

And separately:

> *"LLMs are exceptionally good at looping until they meet specific goals... Don't tell it what to do, give it success criteria and watch it go."*

This repo stitches both observations into one workflow:

1. **Four Karpathy principles** (Think Before Coding / Simplicity First / Surgical Changes / Goal-Driven Execution) address the first set of failure modes.
2. **A "Production-Ready Loop"** with trigger phrases (*"ship it"*, *"don't stop"*, *"loop until done"*) turns Claude loose to self-verify until success criteria are met.
3. **OpenAI Codex as a second model**, woven in at two moments:
   - **`/codex` = navigator** — fires BEFORE Claude presents a non-trivial design, so you see a plan that already survived a second opinion
   - **`/codex-review` = inspector** — fires BEFORE Claude declares victory, as an adversarial completion review
4. **An escalation ladder** (self → /codex → user) so the autonomous loop stays alive longer: when Claude gets stuck mid-loop, it consults Codex before interrupting you.

One-liner for Codex role separation: **Use `/codex` before you commit; use `/codex-review` before you declare victory.**

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
