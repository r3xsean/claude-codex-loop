# codex-run.ps1
#
# REQUIRES: PowerShell 7+ (pwsh). Windows-first. macOS/Linux users must
# port this script to bash/zsh manually — see README.md.
#
# Reusable helper for invoking the OpenAI Codex CLI from the /codex and
# /codex-review Claude Code skills. Optimized for 1-turn skill invocations:
# Claude pipes a prompt in synchronously, the script runs Codex, and prints
# the response + SESSION_ID trailer to stdout — Claude sees it directly in
# the tool result.
#
# Output format (always):
#   OUTFILE: <path to persistent output file>
#   <blank line>
#   <Codex's response>
#   <blank line>
#   ---
#   SESSION_ID: <uuid>
#
# The OUTFILE header comes FIRST so that if the response body gets truncated
# by the tool output size limit (~150K chars for long reviews), Claude can
# still see the path in the surviving prefix and Read the full content as
# a fallback (falling back to 2 turns only when needed).
#
# Features:
#   - -Mode codex|review auto-resolves preamble/postamble/ephemeral per skill
#   - Deterministic session ID capture from --json event stream (race-safe)
#   - Supports -Resume <uuid> for multi-turn conversations
#   - Error capture (writes codex stderr to output file on failure so Claude sees it)
#   - Persistent output file — never auto-deleted, serves as truncation fallback
#
# Usage (typical, from Claude Code skill):
#   <prompt via pipe> | codex-run.ps1 -Mode codex [-Resume <uuid>]
#   <prompt via pipe> | codex-run.ps1 -Mode review
#
# Flags:
#   -Mode codex|review     Auto-resolves preamble, postamble, and ephemeral.
#                          Omit to use explicit flags below.
#   -PromptFile <path>     Alternative to stdin: read prompt from file
#   -PreambleFile <path>   Prepend this file's contents (overrides -Mode default)
#   -PostambleFile <path>  Append this file's contents (overrides -Mode default)
#   -Resume <uuid>         Resume a prior session instead of starting fresh
#   -OutFile <path>        Also persist response to this file (in addition to stdout)
#   -Ephemeral             Don't persist session to disk (review mode sets this)
#   -Model <model>         Override model (default: gpt-5.4)
#   -KeepPromptFile        Don't delete the -PromptFile after the run (debug only)
#   -NoWatch               Suppress the live watcher window. By default, every
#                          run spawns a separate PowerShell window that live-tails
#                          Codex's event stream. Auto-closes 5 minutes after
#                          Codex finishes (or close manually anytime).
#
# Final prompt = <preamble>\n\n<prompt>\n\n<postamble>
#
# Mode resolution:
#   -Mode codex  = preamble: codex-common-preamble.txt, no postamble, persistent session
#   -Mode review = preamble: codex-review-header.txt + codex-common-preamble.txt,
#                  postamble: codex-review-postamble.txt, ephemeral session

[CmdletBinding()]
param(
    [Parameter(ValueFromPipeline=$true)]
    [object]$PipelineInput,

    [Parameter(Mandatory=$false)]
    [ValidateSet("", "codex", "review")]
    [string]$Mode = "",

    [Parameter(Mandatory=$false)]
    [string]$PromptFile = "",

    [Parameter(Mandatory=$false)]
    [string]$PreambleFile = "",

    [Parameter(Mandatory=$false)]
    [string]$PostambleFile = "",

    [Parameter(Mandatory=$false)]
    [string]$Resume = "",

    [Parameter(Mandatory=$false)]
    [string]$OutFile = "",

    [Parameter(Mandatory=$false)]
    [switch]$Ephemeral,

    [Parameter(Mandatory=$false)]
    [string]$Model = "gpt-5.4",

    [Parameter(Mandatory=$false)]
    [switch]$KeepPromptFile,

    [Parameter(Mandatory=$false)]
    [switch]$NoWatch,

    [Parameter(Mandatory=$false)]
    [string]$WatchLog = ""
)

begin {
    $pipelineBuffer = [System.Text.StringBuilder]::new()
}

process {
    if ($null -ne $PipelineInput) {
        [void]$pipelineBuffer.AppendLine($PipelineInput.ToString())
    }
}

end {
    $scriptDir = $PSScriptRoot

    # --- Resolve prompt source ---
    if ($PromptFile) {
        if (-not (Test-Path $PromptFile)) {
            Write-Error "Prompt file not found: $PromptFile"
            exit 1
        }
        $prompt = Get-Content -Path $PromptFile -Raw
    } elseif ($pipelineBuffer.Length -gt 0) {
        $prompt = $pipelineBuffer.ToString()
    } else {
        # Fallback: try reading stdin directly
        $prompt = [Console]::In.ReadToEnd()
    }

    if ([string]::IsNullOrWhiteSpace($prompt)) {
        Write-Error "Empty prompt. Pipe content to stdin or pass -PromptFile <path>."
        exit 1
    }

    # --- Resolve mode-based defaults ---
    # These only apply if the user didn't pass explicit overrides.
    $preambleFiles = @()
    if ($Mode -eq "codex") {
        if (-not $PreambleFile) {
            $preambleFiles = @(Join-Path $scriptDir "codex-common-preamble.txt")
        }
    } elseif ($Mode -eq "review") {
        if (-not $PreambleFile) {
            # Review mode: adversarial header first, then shared rules/CLAUDE.md
            # Parens are required: without them, PowerShell parses
            #   `Join-Path $scriptDir "a.txt", Join-Path $scriptDir "b.txt"`
            # as a single Join-Path call with the comma binding to the second arg.
            $preambleFiles = @(
                (Join-Path $scriptDir "codex-review-header.txt"),
                (Join-Path $scriptDir "codex-common-preamble.txt")
            )
        }
        if (-not $PostambleFile) {
            $PostambleFile = Join-Path $scriptDir "codex-review-postamble.txt"
        }
        if (-not $Ephemeral) {
            $Ephemeral = $true
        }
    }

    # Explicit -PreambleFile overrides mode defaults
    if ($PreambleFile) {
        $preambleFiles = @($PreambleFile)
    }

    # --- Load and prepend preamble(s) ---
    if ($preambleFiles.Count -gt 0) {
        $preambleContent = ""
        foreach ($pf in $preambleFiles) {
            if (-not (Test-Path $pf)) {
                Write-Error "Preamble file not found: $pf"
                exit 1
            }
            $preambleContent += (Get-Content -Path $pf -Raw).TrimEnd() + "`n`n"
        }
        $prompt = $preambleContent.TrimEnd() + "`n`n" + $prompt.TrimStart()
    }

    # --- Load and append postamble (if provided) ---
    if ($PostambleFile) {
        if (-not (Test-Path $PostambleFile)) {
            Write-Error "Postamble file not found: $PostambleFile"
            exit 1
        }
        $postamble = Get-Content -Path $PostambleFile -Raw
        $prompt = $prompt.TrimEnd() + "`n`n" + $postamble.TrimStart()
    }

    # --- Resolve codex output path ---
    # Always write a persistent file. Caller may pass -OutFile to control the
    # path; otherwise we auto-generate one in TEMP. The file is NOT deleted
    # after the run — it serves as a fallback for Claude to Read if the
    # stdout response gets truncated by the tool output limit (~150K chars).
    if (-not $OutFile) {
        $autoId = Get-Date -Format "yyyyMMdd-HHmmss-fff"
        $OutFile = Join-Path $env:TEMP "codex-$autoId.txt"
    }
    $codexOutput = $OutFile

    $streamFile = "$codexOutput.stream.jsonl"
    $errFile = "$codexOutput.err.log"
    $doneFile = "$codexOutput.done"

    # --- Build codex CLI arguments ---
    if ($Resume) {
        # resume takes the UUID as a positional arg; do NOT pass -m (session
        # already has its model baked in)
        $codexArgs = @("exec", "resume", $Resume)
    } else {
        $codexArgs = @("exec", "-m", $Model)
    }

    $codexArgs += @(
        "--dangerously-bypass-approvals-and-sandbox",
        "--skip-git-repo-check",
        "--json",
        "-o", $codexOutput
    )

    if ($Ephemeral) {
        $codexArgs += "--ephemeral"
    }

    # --- Touch stream file so the watcher has something to open immediately ---
    if (-not $NoWatch) {
        New-Item -Path $streamFile -ItemType File -Force | Out-Null

        # Spawn the watcher in a new PowerShell window. It will tail $streamFile
        # until $doneFile appears, then close 5 minutes later.
        $watcherScript = Join-Path $scriptDir "codex-watcher.ps1"
        $watcherArgs = @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", $watcherScript,
            "-StreamFile", $streamFile,
            "-DoneFile", $doneFile
        )
        if ($WatchLog) {
            # Clear any stale log from a prior run
            if (Test-Path $WatchLog) { Remove-Item $WatchLog -ErrorAction SilentlyContinue }
            $watcherArgs += @("-LogFile", $WatchLog)
        }
        Start-Process pwsh -ArgumentList $watcherArgs | Out-Null
    }

    # --- Run codex ---
    # Prompt goes on stdin, JSONL events go to $streamFile, stderr goes to $errFile.
    $prompt | & codex @codexArgs 2>$errFile > $streamFile
    $exitCode = $LASTEXITCODE

    # --- Signal the watcher (if any) that codex has finished ---
    if (-not $NoWatch) {
        New-Item -Path $doneFile -ItemType File -Force | Out-Null
    }

    # --- Extract session ID from first JSON event (thread.started) ---
    $sessionId = $null
    if (Test-Path $streamFile) {
        $firstLine = Get-Content -Path $streamFile -TotalCount 1 -ErrorAction SilentlyContinue
        if ($firstLine) {
            try {
                $firstEvent = $firstLine | ConvertFrom-Json -ErrorAction Stop
                if ($firstEvent.type -eq "thread.started" -and $firstEvent.thread_id) {
                    $sessionId = $firstEvent.thread_id
                }
            } catch {
                # Malformed or unexpected first line — ignore
            }
        }
    }

    # --- Handle failure: write stderr into codex output if nothing was produced ---
    if (-not (Test-Path $codexOutput) -or (Get-Item $codexOutput).Length -eq 0) {
        $errorText = "CODEX ERROR (exit code $exitCode)`n`n"
        if (Test-Path $errFile) {
            $errorText += (Get-Content -Path $errFile -Raw)
        } else {
            $errorText += "(no stderr captured)"
        }
        Set-Content -Path $codexOutput -Value $errorText -Encoding UTF8
    }

    # --- Persist SESSION_ID trailer to output file ---
    if ($sessionId) {
        Add-Content -Path $codexOutput -Value "`n---`nSESSION_ID: $sessionId"
    }

    # --- Read final response content (now includes SESSION_ID trailer) ---
    $responseContent = Get-Content -Path $codexOutput -Raw

    # --- Print to stdout ---
    # OUTFILE header comes FIRST so that if the response body gets truncated
    # by the tool output limit (~150K chars), Claude still sees the file path
    # in the surviving prefix and can Read the full content as a fallback.
    Write-Output "OUTFILE: $codexOutput"
    Write-Output ""
    Write-Output $responseContent.TrimEnd()

    # --- Cleanup temp infrastructure (but keep the output file) ---
    # In watcher mode (default) the watcher window is still reading $streamFile
    # for its 5-minute closing countdown; leave it alone (Windows temp cleanup
    # handles it eventually). $doneFile is tiny and also left for the watcher.
    if ($NoWatch) {
        Remove-Item -Path $streamFile, $errFile -ErrorAction SilentlyContinue
    } else {
        Remove-Item -Path $errFile -ErrorAction SilentlyContinue
    }
    if ($PromptFile -and -not $KeepPromptFile) {
        Remove-Item -Path $PromptFile -ErrorAction SilentlyContinue
    }

    exit $exitCode
}
