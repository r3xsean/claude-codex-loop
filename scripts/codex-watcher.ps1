# codex-watcher.ps1
#
# REQUIRES: PowerShell 7+ (pwsh). Windows-first. macOS/Linux users must
# port this script to bash/zsh manually — see README.md.
#
# Live viewer for Codex JSONL event streams. Spawned by codex-run.ps1 on
# every run (unless -NoWatch is passed). Reads $StreamFile as it's being
# written by `codex exec --json`, pretty-prints events, waits for $DoneFile
# sentinel, then closes 5 minutes later. User can also close the window
# manually at any time — the watcher process is independent of the main
# script, so killing it has no effect on Codex's execution or the main
# response path.
#
# Event schema (verified from real --json streams):
#   top-level: thread.started, turn.started, turn.completed, turn.failed,
#              item.started, item.completed, error
#   item types: command_execution, web_search, agent_message
#     (reasoning/file_read/mcp_tool_call/file_changes appear in recorded
#      session files but NOT in raw --json output — branches for them are
#      defensive in case codex CLI adds them later)

param(
    [Parameter(Mandatory=$true)][string]$StreamFile,
    [Parameter(Mandatory=$true)][string]$DoneFile,
    [Parameter(Mandatory=$false)][string]$LogFile = ""
)

$Host.UI.RawUI.WindowTitle = "Codex Session (live)"

# Write-Line: mirror Write-Host output to an optional plain-text log file
# so the user (or Claude) can review what was shown after the fact.
function Write-Line {
    param(
        [string]$Text = "",
        [System.ConsoleColor]$Color = [System.ConsoleColor]::Gray
    )
    Write-Host $Text -ForegroundColor $Color
    if ($LogFile) {
        Add-Content -Path $LogFile -Value $Text -Encoding UTF8
    }
}

# Strip ANSI escape sequences (colour codes, cursor moves, etc.) that leak
# through from PowerShell error rendering and terminal programs. Without this,
# command output is cluttered with sequences like `[31;1m...[0m`.
function Remove-AnsiCodes {
    param([string]$text)
    if (-not $text) { return $text }
    # CSI sequences: ESC [ ... letter  (e.g. colours, cursor moves)
    $text = $text -replace "`e\[[\d;?]*[a-zA-Z]", ""
    # OSC sequences: ESC ] ... BEL or ESC \
    $text = $text -replace "`e\].*?(`a|`e\\)", ""
    # Bare ESC that survived
    $text = $text -replace "`e", ""
    return $text
}

# Codex on Windows runs everything through a pwsh wrapper:
#   "C:\Program Files\PowerShell\7\pwsh.exe" -Command "<actual command>"
# Strip that wrapper for display so the user sees what Codex is actually doing.
function Simplify-Command {
    param([string]$cmd)
    if (-not $cmd) { return $cmd }
    # Match the pwsh path followed by -Command "..." and extract the inner command.
    # Handles both double-escaped ("...") and single-quoted variants.
    if ($cmd -match '^\s*"?[^"]*pwsh\.exe"?\s+-Command\s+"(.+)"\s*$') {
        return $matches[1] -replace '\\\\', '\'
    }
    if ($cmd -match "^\s*`"?[^`"]*pwsh\.exe`"?\s+-Command\s+'(.+)'\s*$") {
        return $matches[1]
    }
    return $cmd
}

# Display command output compactly. Heuristic:
#   - exit 0 + more than 3 lines  -> hide entirely (noise from successful reads)
#   - exit != 0                   -> show up to 8 lines so errors are debuggable
#   - any short output (<=3 lines) -> show inline
function Format-CommandOutput {
    param(
        [string]$output,
        [object]$exitCode
    )

    if (-not $output) { return }
    $clean = (Remove-AnsiCodes $output).TrimEnd()
    if (-not $clean) { return }

    $lines = $clean -split "`r?`n" | Where-Object { $_.Trim() }
    $lineCount = @($lines).Count

    $isError = ($null -ne $exitCode) -and ($exitCode -ne 0)
    $maxLines = if ($isError) { 8 } else { 3 }

    # Hide bulky successful output — user doesn't need verbatim file dumps
    if (-not $isError -and $lineCount -gt $maxLines) {
        Write-Line "    ($lineCount lines of output)" DarkGray
        return
    }

    $shown = $lines | Select-Object -First $maxLines
    foreach ($line in $shown) {
        $trimmed = $line
        if ($trimmed.Length -gt 200) { $trimmed = $trimmed.Substring(0, 200) + "..." }
        Write-Line "    $trimmed" DarkYellow
    }
    if ($lineCount -gt $maxLines) {
        $more = $lineCount - $maxLines
        Write-Line "    (+$more more)" DarkGray
    }
}

function Format-Event {
    param([string]$line)

    if ([string]::IsNullOrWhiteSpace($line)) { return }

    try {
        $e = $line | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-Line $line DarkGray
        return
    }

    switch ($e.type) {
        "thread.started" {
            Write-Line "-> Session: $($e.thread_id)" Cyan
        }
        "turn.started" {
            Write-Line ""
            Write-Line "--- Turn started ---" Cyan
        }
        "turn.completed" {
            $u = $e.usage
            $msg = "--- Turn done"
            if ($u) {
                $msg += " (in=$($u.input_tokens) cached=$($u.cached_input_tokens) out=$($u.output_tokens))"
            }
            $msg += " ---"
            Write-Line $msg Cyan
        }
        "turn.failed" {
            $msg = if ($e.error) { $e.error } elseif ($e.message) { $e.message } else { "Turn failed" }
            Write-Line "--- Turn FAILED: $msg ---" Red
        }
        "error" {
            $msg = if ($e.message) { $e.message } elseif ($e.error) { $e.error } else { ($e | ConvertTo-Json -Compress -Depth 4) }
            Write-Line "[error] $msg" Red
        }
        "item.started" {
            # Phase-change markers — this is the main feedback loop during a run
            $i = $e.item
            switch ($i.type) {
                "command_execution" {
                    $cmd = Simplify-Command $i.command
                    if ($cmd.Length -gt 120) { $cmd = $cmd.Substring(0, 120) + "..." }
                    Write-Line "  `$ $cmd" Yellow
                }
                "web_search" {
                    Write-Line "  [searching...]" Blue
                }
                "agent_message" {
                    Write-Line "  [writing...]" DarkGreen
                }
                "reasoning" {
                    Write-Line "  [thinking...]" Magenta
                }
                default {
                    Write-Line "  [$($i.type) started]" DarkGray
                }
            }
        }
        "item.completed" {
            $i = $e.item
            switch ($i.type) {
                "agent_message" {
                    Write-Line ""
                    Write-Line $i.text Green
                    Write-Line ""
                }
                "command_execution" {
                    Format-CommandOutput $i.aggregated_output $i.exit_code
                    # Only flag non-zero exit codes — clean runs don't need a trailer
                    if ($null -ne $i.exit_code -and $i.exit_code -ne 0) {
                        Write-Line "    [exit $($i.exit_code)]" Red
                    }
                }
                "web_search" {
                    $q = if ($i.query) { $i.query } else { "(no query recorded)" }
                    Write-Line "    -> $q" Blue
                }
                "reasoning" {
                    # Defensive: `summary` can be an empty array, a string, or a
                    # collection of objects with .text/.summary fields.
                    $parts = @()
                    if ($i.summary -is [string] -and $i.summary.Trim()) {
                        $parts += $i.summary.Trim()
                    } elseif ($i.summary -is [System.Collections.IEnumerable]) {
                        foreach ($s in $i.summary) {
                            if ($s -is [string] -and $s.Trim()) { $parts += $s.Trim() }
                            elseif ($s.text) { $parts += ($s.text.ToString()).Trim() }
                            elseif ($s.summary) { $parts += ($s.summary.ToString()).Trim() }
                        }
                    }
                    if ($parts.Count -gt 0) {
                        $text = $parts -join " | "
                        if ($text.Length -gt 180) { $text = $text.Substring(0, 180) + "..." }
                        Write-Line "    $text" DarkMagenta
                    }
                }
                "error" {
                    $msg = if ($i.message) { $i.message } elseif ($i.error) { $i.error } else { "(item error)" }
                    Write-Line "  [item error] $msg" Red
                }
                "file_changes" {
                    $paths = @()
                    if ($i.files) { $paths = @($i.files | ForEach-Object { if ($_.path) { $_.path } else { "$_" } }) }
                    elseif ($i.path) { $paths = @($i.path) }
                    $label = if ($paths.Count -gt 0) { ($paths | Select-Object -First 3) -join ", " } else { "(files changed)" }
                    Write-Line "  [edit] $label" Green
                }
                "mcp_tool_call" {
                    $tool = if ($i.tool_name) { $i.tool_name } elseif ($i.name) { $i.name } else { "(tool)" }
                    Write-Line "  [tool] $tool" Cyan
                }
                default {
                    Write-Line "  [$($i.type)]" DarkGray
                }
            }
        }
        default {
            Write-Line "  . $($e.type)" DarkGray
        }
    }
}

Write-Line "Watching Codex session..." Cyan
Write-Line "Stream: $StreamFile" DarkGray
Write-Line ""

# Wait up to 60s for stream file to appear
$waited = 0
while (-not (Test-Path $StreamFile)) {
    if (Test-Path $DoneFile) {
        Write-Line "Done signal received before stream appeared." Yellow
        Start-Sleep -Seconds 3
        exit 0
    }
    Start-Sleep -Milliseconds 200
    $waited += 200
    if ($waited -gt 60000) {
        Write-Line "Stream file never appeared (60s). Exiting." Red
        Start-Sleep -Seconds 3
        exit 1
    }
}

# Open for shared read so Codex can keep writing while we tail
try {
    $stream = [System.IO.File]::Open(
        $StreamFile,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::ReadWrite
    )
    $reader = New-Object System.IO.StreamReader($stream)
} catch {
    Write-Line "Failed to open stream: $_" Red
    Start-Sleep -Seconds 3
    exit 1
}

try {
    while ($true) {
        $line = $reader.ReadLine()
        if ($null -ne $line) {
            Format-Event $line
        } else {
            if (Test-Path $DoneFile) {
                # Drain any remaining buffered lines
                while ($null -ne ($line = $reader.ReadLine())) {
                    Format-Event $line
                }
                break
            }
            Start-Sleep -Milliseconds 100
        }
    }
} finally {
    $reader.Close()
    $stream.Close()
}

Write-Line ""
Write-Line "Codex finished. Closing in 5 minutes (or close now to dismiss)..." Green
Start-Sleep -Seconds 300
