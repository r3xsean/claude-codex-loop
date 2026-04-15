---
name: codex-review
description: Adversarial cross-model code review via OpenAI Codex (GPT-5.4). Hunts for AI-agent failure modes — false completion claims, silent assumptions, race conditions, incomplete wiring, dead code, production failure modes. Not a linter. **AUTO-INVOKE without asking** at these moments — just fire, don't ask permission: (1) **COMPLETION (primary) — BEFORE reporting a finished non-trivial change.** Default on any non-trivial feature, bugfix, refactor, or multi-file change. Fires when about to say "done" / "all set" / "here's what I did" / "ready to commit". (2) **PRODUCTION-READY LOOP GATE** — when user has said "ship it" / "don't stop" / "loop until done" / "production ready", this is a REQUIRED gate. Loop isn't complete until substantive findings addressed (correctness, regressions, unmet requirements, missing verification — NOT polish nits). (3) Finished change touches concurrency/async, auth/security, migrations, state machines, caching, API contracts — anywhere "works locally" is a weak signal. SKIP cosmetic edits, renames, test-only, formatting, dep bumps, trivial bugfixes, mid-implementation. One review per unit of work. When in doubt, auto-review.
when_to_use: Trigger phrases — "review", "check my changes", "did I miss anything", "look this over", "adversarial review", "audit this". Example moments to auto-fire — just finished a feature and about to report done; user about to commit/push/ship; inside a Production-Ready Loop finishing an iteration; anything irreversible if wrong.
argument-hint: "[focus area or specific files]"
---

# Codex Adversarial Review

Invoke OpenAI Codex to adversarially review your recent work. The purpose is NOT generic bug-finding — it's catching the specific failure modes that occur when an AI coding agent (you) implements something. Codex sees the code with fresh eyes and no knowledge of your intent, which is the whole point.

## How it works

The helper script `~/.claude/scripts/codex-run.ps1` handles everything. You compose the context briefing, pipe it to the script with `-Mode review` in a backgrounded PowerShell tool call, and Read the task's output file when the completion notification arrives.

**Backgrounded for safety** — reviews regularly take 5-10+ minutes and synchronous PowerShell tool calls have a 10-minute cap. Background mode has no timeout. The script's response + findings get captured as the task's output file, which Claude Reads when the notification arrives.

Reviews are **always stateless** — each review is a fresh Codex session with no memory of prior reviews. `-Mode review` sets `-Ephemeral` automatically so session files don't pile up. No bias carries between reviews of unrelated changes.

## Auto-invoke at completion — default behavior

**You should auto-invoke `/codex-review` at COMPLETION moments, without asking.** The user has explicitly opted into this behavior: budget is not a constraint, and the watcher window popping up is fine.

A **completion moment** is when you're about to report a finished non-trivial change to the user. Specifically:

- You finished implementing a feature, bugfix, or refactor and are about to say "done" / "all set" / "here's what I did"
- You just made the final edit in a multi-step implementation
- The user is about to commit, push, or ship
- You reached a natural stopping point where the change is cohesive and reviewable

**One review per meaningful unit of work, NOT per file-edit.** If you're in the middle of a multi-step implementation and still have more edits planned, do NOT review yet. Wait until the whole unit is done. The user can interrupt mid-implementation by asking explicitly — that's fine — but don't auto-review during active work.

**What counts as non-trivial** (auto-review these):
- Any code change touching concurrency/async, auth/security, migrations, state machines, caching, API contracts
- New features (even small ones) that integrate multiple pieces
- Refactors that change behavior, not just structure
- Anything where "works locally" is a weak signal
- Anything you yourself felt uncertain about while implementing

**What counts as trivial** (skip auto-review):
- Typos, formatting, renames with no behavior change
- Config/dependency bumps with no code path changes you own
- Comment-only edits
- Single-line bugfixes where the fix is obviously correct
- Test-only additions
- Generated code (migrations, schema dumps, etc.) that you didn't write

When in doubt, **auto-review**. False positives (running a review that turns out to be trivial) are cheap. False negatives (shipping a subtle bug that Codex would have caught) are expensive.

## Step 1: Gather context for the review

If `$ARGUMENTS` specifies files or a focus area, use that to scope the review.
If `$ARGUMENTS` is empty, review all uncommitted changes.

Get the diff by running `git diff --stat HEAD` yourself via the PowerShell tool (do NOT use a `!` auto-exec block — the working directory may not be a git repo). If not in a git repo, ask the user which files or directory to review instead.

Before composing the prompt, thoroughly review the diff yourself AND assemble a rich briefing for Codex.

**ALWAYS include these two — every review, no exceptions — so Codex knows EXACTLY what the user wants:**

- **Verbatim user constraints** — quote any hard requirements the user stated word-for-word. Do not paraphrase. Includes negative constraints ("don't touch X", "no new dependencies", "must work on Windows PowerShell").
- **Exact user wording for the original ask** — paste the user's actual request verbatim, not your interpretation. Codex needs to see what the user said, not what Claude understood. Quoting is cheap insurance against Claude's paraphrase silently dropping a load-bearing word.

**Then assemble the rest of the briefing:**

- **What you implemented and WHY** — the user's original request, the goal, constraints
- **Files touched** — absolute paths, so Codex knows exactly where to look
- **Related files NOT in the diff** — callers, shared types, tests, config. Point Codex at these paths.
- **Judgment calls and tradeoffs** — intentional decisions you don't want flagged
- **Known unknowns** — things you're genuinely unsure about; ask Codex to focus there
- **Approaches already tried and abandoned** — so Codex doesn't suggest them
- **Test coverage** — what's tested, what isn't, whether tests were run
- **Project conventions** — anything from CLAUDE.md relevant to the changed code
- **Environment/platform quirks** — Windows, PowerShell, specific runtime versions

You'll need this context twice: (1) to inject into Codex's prompt, and (2) for triage in Step 4.

## Step 2: Compose the review prompt

**You do NOT need to write the adversarial framing, CRITICAL RULES, CLAUDE.md instructions, or review workflow** — the script automatically prepends `~/.claude/scripts/codex-review-header.txt` (adversarial framing) + `~/.claude/scripts/codex-common-preamble.txt` (rules + CLAUDE.md) and appends `~/.claude/scripts/codex-review-postamble.txt` (workflow + severity + verdict format).

Your prompt content should contain ONLY the rich context briefing from Step 1 plus the explicit scope and git diff command. Structure:

```
## Context from Claude's session

<your rich briefing: user's goal, files touched, related files to read,
 hypothesis, judgment calls, known unknowns, approaches rejected, test
 coverage, project conventions, platform quirks>

## Review scope

<the user's $ARGUMENTS, or "all uncommitted changes" if no args>

To see the actual changes, run:
<exact git diff command based on scope:
 - all uncommitted: `git diff HEAD`
 - specific files:  `git diff HEAD -- <file1> <file2> ...`
 - committed: use `git log -5 --oneline` then `git show <commit>`>
```

Err on the side of MORE context — this is a synchronous tool call with a generous timeout. A 3000-token briefing that gets a surgical review beats a 200-token prompt that gets generic nitpicks. The postamble picks up from your scope/git-diff command and instructs Codex to run it as its FIRST step before evaluating.

## Step 3: Invoke the script (backgrounded)

```powershell
@'
<Claude: replace this entire block with your composed context briefing per the structure above>
'@ | & "$env:USERPROFILE\.claude\scripts\codex-run.ps1" -Mode review
```

The command automatically spawns the live watcher window so the user can watch Codex run git diffs, read files, and surface findings in real time. Append `-NoWatch` only if the user explicitly wants to suppress the window.

**Critical — use single-quoted here-strings (`@'...'@`)**, NOT double-quoted. Diff content, error traces, and code often contain `${`, `$(`, backticks, or template placeholders that would crash a double-quoted here-string. Single-quoted treats everything as literal. The closing `'@` MUST be at column 0 (no leading whitespace).

**Run with `run_in_background: true`.** Reviews regularly take 5-10+ minutes — background mode has no timeout cap, synchronous does (10 min max).

**Do NOT send a preamble message announcing the review.** No "Codex review running", no "let me ask Codex to review this", no "this may take a few minutes". Invoke the PowerShell tool directly with no accompanying text. The watcher window pops up immediately and the user can see it's running — a verbal announcement just wastes a turn. Save all your text output for the triage in Step 4.

## Step 4: Read and triage the results

When the task completion notification arrives, **immediately use the Read tool** on the task's output file (the path is in the `<output-file>` tag of the notification). It contains:

```
OUTFILE: $env:TEMP\codex-<timestamp>.txt

<Codex's review findings>

VERDICT: APPROVED | REVISE

---
SESSION_ID: <uuid>
```

**If truncated** (very long review): the `OUTFILE:` header at the top points to a persistent copy of the full response. Read that path instead.

**If Codex error** (rate limit, crash): output will start with `CODEX ERROR` followed by stderr. Surface it to the user.

### Triage — this is where you earn your keep

**The user already saw Codex's full review live in the watcher window.** Do NOT paste the findings back verbatim or re-enumerate them in your own words — that's just noise. Jump straight into verification and triage. Your value here is cross-referencing Codex's claims against the actual code, not restating them.

Go through each finding by reference (e.g., "Codex's CRITICAL #1 about the race condition in `auth.ts:42`...") and give your verdict:

**If Codex is RIGHT:** Confirm it. Read the file if needed, apply the fix or present it for approval. Don't be defensive about your own code.

**If Codex is WRONG:** Explain specifically why — cite the line that handles the case Codex missed, or explain the design decision that makes the finding irrelevant. Don't just say "false positive" — prove it.

**If Codex is PARTIALLY RIGHT:** Acknowledge the valid part, explain what's already handled, address the remaining gap.

For the COMPLETENESS, ASSUMPTIONS, and DEAD CODE sections: verify each claim. These are where Codex provides the most unique value — they catch things you literally cannot catch by reviewing your own work.

Final summary (terse):
- Findings accepted (with fixes applied or proposed)
- Findings rejected (with specific reasoning)
- Verdict agreement or disagreement with Codex

If the entire review was clean and you have no disagreements, say so in one line: "Codex found N issues, all valid, all fixed" or "Codex approved — no findings to triage." Don't pad.

The only exception to "don't regurgitate": if `-NoWatch` was passed (user suppressed the window), they did NOT see the findings live — in that case, summarize the critical/high findings briefly before your triage so they have enough context to evaluate your decisions.

## Script flags reference

`-Mode review` automatically sets:
- Preamble: `codex-review-header.txt` + `codex-common-preamble.txt`
- Postamble: `codex-review-postamble.txt`
- `-Ephemeral` (no session persistence — reviews are always stateless)

Other relevant flags:
- `-OutFile <path>` — override the auto-generated output file path
- `-KeepPromptFile` — debug only (doesn't apply with pipe input anyway)
- `-NoWatch` — suppress the live watcher window. By default, every review spawns a separate PowerShell window that live-tails Codex's event stream (git diffs, file reads, findings as they appear). Auto-closes 5 minutes after the review finishes, or the user can dismiss it manually. Pass `-NoWatch` only when the user explicitly asks to "not show the window", "hide the watcher", "run quietly", or similar — watching is usually most valuable for reviews since they take the longest.

The preamble/postamble files are static. To change the adversarial framing, CRITICAL RULES, or review workflow across all future reviews, edit those files, not this skill.

## Notes

- Codex runs with `--dangerously-bypass-approvals-and-sandbox` because the Windows sandbox blocks file reads. Review-only behavior is enforced by the preamble, not the sandbox. Git is your safety net if Codex somehow modifies files.
- Budget: reasoning effort is set to `medium` globally. Plus plan allows ~15-20 reviews per week. Don't waste them on trivial changes — save reviews for meaningful implementations.
- There is also a built-in `codex exec review` subcommand — but the custom preamble + postamble gives better adversarial results than the default review.
