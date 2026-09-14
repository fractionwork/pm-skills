# factory-setup.ps1 — one command from a bare Windows machine to working plugins.
#
# The native-Windows sibling of factory-setup.sh. Same five phases, same
# contract: every phase is idempotent, a phase that fails does not stop the ones
# after it, and failures are collected and printed once at the end.
#
# THIS IS FOR WINDOWS WITHOUT WSL. If the machine has WSL, run factory-setup.sh
# inside the distro instead — it is the better-supported path and this script
# says so on startup. This exists because "install WSL first" is not an answer
# for a locked-down or unfamiliar box.
#
# WHAT IT DELIBERATELY DOES NOT DO, inherited from the .sh and worth restating:
# copying skills, registering MCP servers and editing CLAUDE.md are the plugin
# system's job. This script's remit is strictly what has to happen BEFORE or
# OUTSIDE Claude Code. If a plugin can do it, this must not.
#
# WHERE IT HONESTLY DIFFERS FROM THE .sh, because a port that pretends parity is
# worse than one that names the gap:
#
#   * Git for Windows is treated as REQUIRED, not optional. Anthropic lists it
#     as optional for Claude Code and for plain Claude Code it is. For these
#     kits it is load-bearing: Claude Code runs a hook's shell-form command
#     through Git Bash on Windows and through PowerShell when Git Bash is
#     absent, and several kits ship `.sh` skills. Without it pm-kit's
#     SessionStart hook is handed to PowerShell and fails silently.
#
#   * The factory token goes into Claude Code's settings.json, not ~/.devhawk/env.
#     That file is sourced by a login shell; nothing on Windows reads it.
#
#   * pm-kit's Asana MCP server does not work here, and this script does not
#     pretend otherwise. See Phase 4.
#
# Usage:
#   irm https://raw.githubusercontent.com/fractionwork/pm-skills/main/plugins/pm-kit/skills/_shared/factory-setup.ps1 | iex
#
#   # with arguments, which `iex` cannot pass:
#   & ([scriptblock]::Create((irm <url>))) -Role engineer -Yes
#
#   .\factory-setup.ps1 -Check              # report state, change nothing
#   .\factory-setup.ps1 -Role engineer -Yes # non-interactive
#
# Roles: pm · engineer · devhawk · auditor · all

[CmdletBinding()]
param(
  [switch]$Check,
  [switch]$Yes,
  [ValidateSet('pm', 'engineer', 'devhawk', 'auditor', 'all')]
  [string]$Role
)

# NOT `$ErrorActionPreference = 'Stop'`: one failing phase must never abort the
# rest. The summary is the contract, and it can only be honest if execution
# reaches it. Individual calls opt into Stop where a failure is worth catching.
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'   # winget's progress bar corrupts piped output

$script:NODE_MAJOR = 24
$script:PRIVATE_MARKETPLACE = 'fractionwork/software-factory-tools'
$script:MARKETPLACE_NAME = 'software-factory-tools'
$script:FAILED = [System.Collections.Generic.List[string]]::new()
# Whether this run put anything new on PATH. Drives the closing notice: a
# "restart your terminal" banner that fires every time is one people stop
# reading, and then miss on the one run where it mattered.
$script:PATH_CHANGED = $false

# ── output ──────────────────────────────────────────────────────────────────

function Write-Ok   { param([string]$m) Write-Host '  ✓ ' -ForegroundColor Green  -NoNewline; Write-Host $m }
function Write-Warn { param([string]$m) Write-Host '  ⊙ ' -ForegroundColor Yellow -NoNewline; Write-Host $m }
function Write-Bad  { param([string]$m) Write-Host '  ✗ ' -ForegroundColor Red    -NoNewline; Write-Host $m }
function Write-Say  { param([string]$m = '') Write-Host "    $m" }
function Write-Step { param([string]$m) Write-Host ''; Write-Host $m -ForegroundColor White }
function Add-Failure { param([string]$m) $script:FAILED.Add($m) | Out-Null }

# ── small helpers ───────────────────────────────────────────────────────────

function Test-Have {
  param([Parameter(Mandatory)][string]$Name)
  [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

<#
Re-read PATH from the registry into this session.

winget writes the machine and user PATH, and a PowerShell session that is
already running never sees it. On the .sh side the equivalent problem ends in
"ran the installer again, claude is still not found" — the install was fine, the
shell was stale. Here we can actually fix it rather than only warn, so we do
both: refresh now, and still say so at the end for anything spawned elsewhere.
#>
function Update-SessionPath {
  $parts = @(
    [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
    [System.Environment]::GetEnvironmentVariable('Path', 'User')
  ) | Where-Object { $_ }
  if ($parts) { $env:Path = ($parts -join ';') }
}

<#
Every kit a role installs.

Kept identical to kits_for_role() in factory-setup.sh. The two lists drifting
apart would give a Windows engineer a different factory from a WSL one, which is
exactly the sort of difference nobody thinks to check.
#>
function Get-KitsForRole {
  param([Parameter(Mandatory)][string]$Name)
  switch ($Name) {
    'pm'       { @('pm-kit', 'factory-kit') }
    'engineer' { @('pm-kit', 'ship-kit', 'factory-kit') }
    'devhawk'  { @('pm-kit', 'ship-kit', 'devhawk-kit', 'factory-kit') }
    'auditor'  { @('audit-kit') }
    'all'      { @('pm-kit', 'ship-kit', 'devhawk-kit', 'audit-kit', 'factory-kit') }
    default    { @() }
  }
}

<#
How each kit fares on native Windows, and why.

Stated as data rather than prose so the role summary, the -Check report and the
closing notes cannot disagree with each other. Derived from what each kit
actually invokes: a kit with no shell scripts that calls `node` and `git` has
nothing platform-specific left to break.
#>
function Get-KitWindowsStatus {
  param([Parameter(Mandatory)][string]$Kit)
  switch ($Kit) {
    'ship-kit'    { @{ State = 'ok';       Note = '' } }
    'factory-kit' { @{ State = 'ok';       Note = '' } }
    'pykit'       { @{ State = 'ok';       Note = '' } }
    'devhawk-kit' { @{ State = 'ok';       Note = 'its DigitalOcean deploy scripts need Git Bash' } }
    'audit-kit'   { @{ State = 'degraded'; Note = 'scanners install by hand — /audit-install-scanners has no Windows path' } }
    'pm-kit'      { @{ State = 'degraded'; Note = 'skills and hooks work; the Asana MCP server does not start' } }
    default       { @{ State = 'ok';       Note = '' } }
  }
}

function Get-NodeMajor {
  param([string]$Version)
  if ($Version -match '^v?(\d+)\.') { return [int]$Matches[1] }
  return 0
}

function Test-NodeOk {
  param([string]$Version)
  (Get-NodeMajor $Version) -ge $script:NODE_MAJOR
}

<#
Git Bash, which is the Bash tool on Windows.

Probed rather than assumed: Git for Windows is installable to a user profile, to
a 32-bit Program Files, or through winget's own package root, and Claude Code
only looks in the usual places. Returning the path lets us write it into
settings.json so that guesswork happens once, here, instead of on every launch.
#>
function Find-GitBash {
  $candidates = @(
    "$env:ProgramFiles\Git\bin\bash.exe"
    "${env:ProgramFiles(x86)}\Git\bin\bash.exe"
    "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe"
  )
  foreach ($c in $candidates) { if ($c -and (Test-Path -LiteralPath $c)) { return $c } }

  # Fall back to whatever `git` itself is: <root>\cmd\git.exe -> <root>\bin\bash.exe
  $git = Get-Command git -ErrorAction SilentlyContinue
  if ($git) {
    $root = Split-Path (Split-Path $git.Source -Parent) -Parent
    $bash = Join-Path $root 'bin\bash.exe'
    if (Test-Path -LiteralPath $bash) { return $bash }
  }
  return $null
}

function Get-ClaudeSettingsPath { Join-Path $env:USERPROFILE '.claude\settings.json' }

<#
Merge one key into settings.json's `env` block, preserving everything else.

READ-MODIFY-WRITE, never overwrite. This file is the user's, not ours — it may
already carry an auto-update channel, permissions, or another env var, and an
installer that flattens it is an installer people stop running. A backup is
taken on the first write of each run for the same reason.

Written without a BOM: PowerShell 5.1's `Set-Content -Encoding UTF8` emits one,
and a BOM ahead of `{` is the kind of thing a strict JSON parser rejects while
the file looks perfect in an editor.
#>
function Set-ClaudeSettingsEnv {
  param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$Value,
    [string]$Path = (Get-ClaudeSettingsPath)
  )

  $dir = Split-Path $Path -Parent
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

  $settings = [pscustomobject]@{}
  if (Test-Path -LiteralPath $Path) {
    $raw = Get-Content -LiteralPath $Path -Raw
    if ($raw -and $raw.Trim()) {
      try {
        $settings = $raw | ConvertFrom-Json
      } catch {
        # A settings file we cannot parse is not ours to repair, and guessing
        # would destroy it. Refuse, and say where the value has to go by hand.
        throw "settings.json exists but is not valid JSON: $Path"
      }
    }
    Copy-Item -LiteralPath $Path -Destination "$Path.bak" -Force -ErrorAction SilentlyContinue
  }

  if (-not $settings.PSObject.Properties['env']) {
    $settings | Add-Member -NotePropertyName 'env' -NotePropertyValue ([pscustomobject]@{})
  }
  if ($settings.env.PSObject.Properties[$Name]) {
    $settings.env.$Name = $Value
  } else {
    $settings.env | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
  }

  $json = $settings | ConvertTo-Json -Depth 20
  [System.IO.File]::WriteAllText($Path, $json, [System.Text.UTF8Encoding]::new($false))
  return $Path
}

function Get-ClaudeSettingsEnv {
  param([Parameter(Mandatory)][string]$Name, [string]$Path = (Get-ClaudeSettingsPath))
  if (-not (Test-Path -LiteralPath $Path)) { return $null }
  try { $s = (Get-Content -LiteralPath $Path -Raw) | ConvertFrom-Json } catch { return $null }
  if ($s.PSObject.Properties['env'] -and $s.env.PSObject.Properties[$Name]) { return $s.env.$Name }
  return $null
}

function Confirm-Step {
  param([Parameter(Mandatory)][string]$Question, [string]$Default = 'yes')
  if ($Yes) { return ($Default -eq 'yes') }
  $hint = if ($Default -eq 'yes') { 'Y/n' } else { 'y/N' }
  $a = (Read-Host "    $Question [$hint]").Trim()
  if (-not $a) { return ($Default -eq 'yes') }
  return $a -match '^[Yy]'
}

function Read-Secret {
  param([Parameter(Mandatory)][string]$Label)
  $secure = Read-Host "    $Label (input hidden)" -AsSecureString
  if (-not $secure -or $secure.Length -eq 0) { return '' }
  $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
  try { return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr).Trim() }
  finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

<#
Install one winget package, idempotently.

`winget install` on an already-present package exits non-zero with
"No newer package versions are available", which reads as a failure and is not
one. Checking `winget list` first keeps a re-run quiet and keeps the failure
summary honest.
#>
function Install-WingetPackage {
  param(
    [Parameter(Mandatory)][string]$Id,
    [Parameter(Mandatory)][string]$Label,
    [string]$ProbeCommand
  )

  if ($ProbeCommand -and (Test-Have $ProbeCommand)) { Write-Ok "$Label already installed"; return $true }

  $listed = & winget list --id $Id --exact --accept-source-agreements 2>&1 | Out-String
  if ($LASTEXITCODE -eq 0 -and $listed -match [regex]::Escape($Id)) {
    Write-Ok "$Label already installed"
    Update-SessionPath
    return $true
  }

  Write-Say "installing $Label…"
  & winget install --id $Id --exact --silent `
      --accept-package-agreements --accept-source-agreements 2>&1 | Out-Null
  if ($LASTEXITCODE -eq 0) {
    Write-Ok "installed $Label"
    $script:PATH_CHANGED = $true
    Update-SessionPath
    return $true
  }

  Write-Bad "could not install $Label (winget exit $LASTEXITCODE)"
  Add-Failure "$Label (retry: winget install --id $Id --exact)"
  return $false
}

function Get-ClaudeVersion {
  if (-not (Test-Have 'claude')) { return $null }
  try { return (& claude --version 2>$null | Select-Object -First 1) } catch { return $null }
}

# ── role ────────────────────────────────────────────────────────────────────

function Request-Role {
  if ($Role) { return $Role }
  if ($Yes)  { return 'engineer' }

  Write-Host ''
  Write-Host '  Which kits do you want?' -ForegroundColor White
  Write-Host ''
  Write-Say '1  PM / delivery      pm-kit factory-kit           boards, no repository cloned'
  Write-Say '2  Engineer           + ship-kit                   writing code            (default)'
  Write-Say '3  DevHawk engineer   + devhawk-kit                onboarding + the stack'
  Write-Say '4  Auditor            audit-kit                    auditing a codebase'
  Write-Say '5  Everything'
  Write-Host ''
  $a = (Read-Host '    Choose 1-5 [2]').Trim()
  switch ($a) {
    '1'     { 'pm' }
    '3'     { 'devhawk' }
    '4'     { 'auditor' }
    '5'     { 'all' }
    default { 'engineer' }
  }
}

# ── phase 1: prerequisites ──────────────────────────────────────────────────

function Invoke-PhasePrereqs {
  param([string[]]$Kits)
  Write-Step '1/5  Prerequisites'

  if (-not (Test-Have 'winget')) {
    Write-Bad 'winget is not available'
    Write-Say 'winget ships as "App Installer". On Windows 10 it may be absent or too old.'
    Write-Say 'Install it from the Microsoft Store, then re-run this script.'
    Add-Failure 'winget (install "App Installer" from the Microsoft Store)'
    return
  }
  Write-Ok 'winget'

  # Git FIRST, and not for git's sake. Git Bash is the Bash tool on Windows, and
  # without it every `.sh` the kits ship is handed to PowerShell.
  Install-WingetPackage -Id 'Git.Git' -Label 'Git for Windows' -ProbeCommand 'git' | Out-Null

  $bash = Find-GitBash
  if ($bash) {
    Write-Ok "Git Bash at $bash"
    $existing = Get-ClaudeSettingsEnv -Name 'CLAUDE_CODE_GIT_BASH_PATH'
    if (-not $existing) {
      try {
        Set-ClaudeSettingsEnv -Name 'CLAUDE_CODE_GIT_BASH_PATH' -Value $bash | Out-Null
        Write-Ok 'recorded CLAUDE_CODE_GIT_BASH_PATH in settings.json'
      } catch {
        Write-Warn "could not write settings.json: $($_.Exception.Message)"
        Add-Failure 'CLAUDE_CODE_GIT_BASH_PATH (add it to ~/.claude/settings.json by hand)'
      }
    } else {
      Write-Ok 'CLAUDE_CODE_GIT_BASH_PATH already set'
    }
  } else {
    Write-Bad 'Git Bash not found after installing Git'
    Write-Say 'Several kits ship .sh skills, and pm-kit ships a SessionStart hook.'
    Write-Say 'Without Git Bash those are handed to PowerShell and fail silently.'
    Add-Failure 'Git Bash (set CLAUDE_CODE_GIT_BASH_PATH in ~/.claude/settings.json)'
  }

  Install-WingetPackage -Id 'GitHub.cli' -Label 'gh' -ProbeCommand 'gh' | Out-Null

  # Node is version-sensitive in a way winget's LTS package does not guarantee
  # forever, so check rather than trust.
  if (Test-Have 'node') {
    $v = (& node -v 2>$null)
    if (Test-NodeOk $v) {
      Write-Ok "Node $v"
    } else {
      Write-Warn "Node $v is below $($script:NODE_MAJOR) — the kits' scripts need $($script:NODE_MAJOR)+"
      Install-WingetPackage -Id 'OpenJS.NodeJS.LTS' -Label "Node $($script:NODE_MAJOR)+" | Out-Null
      $v2 = (& node -v 2>$null)
      if (-not (Test-NodeOk $v2)) {
        Write-Bad "still on Node $v2 — a second Node may be earlier on PATH"
        Add-Failure "Node $($script:NODE_MAJOR)+ (check: where.exe node)"
      }
    }
  } else {
    Install-WingetPackage -Id 'OpenJS.NodeJS.LTS' -Label 'Node' -ProbeCommand $null | Out-Null
  }

  # Claude Code itself. winget's package does not auto-update, so prefer the
  # native installer, which does — matching what the .sh does on the other side.
  if (Test-Have 'claude') {
    Write-Ok "Claude Code $(Get-ClaudeVersion)"
  } else {
    Write-Say 'installing Claude Code…'
    try {
      Invoke-RestMethod 'https://claude.ai/install.ps1' -ErrorAction Stop | Invoke-Expression
      Update-SessionPath
      $script:PATH_CHANGED = $true
      if (Test-Have 'claude') { Write-Ok "Claude Code $(Get-ClaudeVersion)" }
      else { Write-Warn 'Claude Code installed but not yet on this session PATH' }
    } catch {
      Write-Bad "Claude Code install failed: $($_.Exception.Message)"
      Add-Failure 'Claude Code (retry: irm https://claude.ai/install.ps1 | iex)'
    }
  }

  if ($Kits -contains 'pm-kit') {
    if (Test-Have 'python') { Write-Ok "Python $((& python --version 2>&1) -replace 'Python ','')" }
    else { Install-WingetPackage -Id 'Python.Python.3.13' -Label 'Python 3.13' -ProbeCommand 'python' | Out-Null }
  }
}

# ── phase 2: github ─────────────────────────────────────────────────────────

function Invoke-PhaseGitHub {
  Write-Step '2/5  GitHub'

  if (-not (Test-Have 'gh')) {
    Write-Bad 'gh is not installed — skipping'
    Add-Failure 'GitHub auth (no gh)'
    return
  }

  & gh auth status 2>&1 | Out-Null
  if ($LASTEXITCODE -eq 0) { Write-Ok 'already authenticated to GitHub'; return }

  if ($Yes) {
    Write-Bad 'not authenticated, and -Yes cannot complete a browser login'
    Write-Say 'run: gh auth login'
    Add-Failure 'GitHub auth (run: gh auth login)'
    return
  }

  Write-Say 'The marketplace repo is PRIVATE, so this is not optional.'
  Write-Say 'Choose HTTPS and let gh be your git credential helper.'
  & gh auth login
  & gh auth status 2>&1 | Out-Null
  if ($LASTEXITCODE -eq 0) {
    Write-Ok 'authenticated'
  } else {
    Write-Bad 'still not authenticated'
    Add-Failure 'GitHub auth (run: gh auth login)'
  }
}

# ── phase 3: marketplace ────────────────────────────────────────────────────

function Invoke-PhaseMarketplace {
  Write-Step '3/5  Marketplace'

  if (-not (Test-Have 'claude')) {
    Write-Bad 'Claude Code is not installed — skipping'
    Add-Failure 'marketplace (no claude)'
    return
  }

  $existing = & claude plugin marketplace list 2>&1 | Out-String
  if ($existing -match [regex]::Escape($script:MARKETPLACE_NAME)) {
    Write-Ok "marketplace already added: $($script:PRIVATE_MARKETPLACE)"
    return
  }

  & claude plugin marketplace add $script:PRIVATE_MARKETPLACE 2>&1 | Out-Null
  if ($LASTEXITCODE -eq 0) {
    Write-Ok "added marketplace: $($script:PRIVATE_MARKETPLACE)"
  } else {
    Write-Bad "could not add marketplace: $($script:PRIVATE_MARKETPLACE)"
    Write-Say 'this repo is private — a not-found here is usually a permissions problem,'
    Write-Say "not a typo. Confirm with: gh repo view $($script:PRIVATE_MARKETPLACE)"
    Add-Failure "marketplace $($script:PRIVATE_MARKETPLACE)"
  }
}

# ── phase 4: plugins ────────────────────────────────────────────────────────

function Invoke-PhasePlugins {
  param([string[]]$Kits)
  Write-Step '4/5  Plugins'

  if (-not (Test-Have 'claude')) {
    Write-Bad 'Claude Code is not installed — skipping'
    Add-Failure 'plugins (no claude)'
    return
  }

  $installed = & claude plugin list 2>&1 | Out-String
  foreach ($k in $Kits) {
    if ($installed -match [regex]::Escape($k)) { Write-Ok "$k already installed"; continue }
    & claude plugin install "$k@$($script:MARKETPLACE_NAME)" 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Ok "installed $k" }
    else { Write-Bad "could not install $k"; Add-Failure "plugin $k" }
  }

  # pm-kit's Python runtime. The .sh runs pm-setup.sh --deps-only here; that
  # cannot work on Windows and saying nothing would leave somebody waiting for
  # Asana tools that are never going to appear.
  if ($Kits -contains 'pm-kit') {
    Write-Host ''
    Write-Warn 'pm-kit: the Asana MCP server does not run on native Windows'
    Write-Say 'Two independent reasons, and fixing one leaves the other:'
    Write-Say '  1. .mcp.json spawns pm-python.sh, and Windows cannot execute a .sh'
    Write-Say '     as a process. A stdio server that dies in the handshake registers'
    Write-Say '     nothing, so the Asana tools are simply absent — with no error.'
    Write-Say '  2. /pm-setup resolves venv/bin/python; a Windows venv is'
    Write-Say '     venv\Scripts\python.exe, so it builds a venv it cannot then find.'
    Write-Say ''
    Write-Say 'Its SKILLS and its session hook are unaffected. For board work, use'
    Write-Say '/factory-connect — that path reaches Asana, Linear and Azure DevOps'
    Write-Say 'through the engine and stores no board credential on this machine.'
    Add-Failure 'pm-kit Asana MCP (not supported on native Windows — use /factory-connect)'
  }

  # audit-kit's scanners. install-scanners.sh reaches for brew, pip, pipx, go and
  # curl, none of which describes a Windows box, so do the two that winget has
  # and name the third rather than leaving all three to fail one by one.
  if ($Kits -contains 'audit-kit') {
    Write-Host ''
    if ($Yes -or (Confirm-Step 'install audit-kit''s scanners (trivy, gitleaks)?')) {
      Install-WingetPackage -Id 'AquaSecurity.Trivy'  -Label 'trivy'    -ProbeCommand 'trivy'    | Out-Null
      Install-WingetPackage -Id 'Gitleaks.Gitleaks'   -Label 'gitleaks' -ProbeCommand 'gitleaks' | Out-Null
      Write-Say 'semgrep is not in winget and its native Windows support is beta.'
      Write-Say 'If you want it:  pipx install semgrep'
      Write-Say 'and set PYTHONUTF8=1, or it fails on files it reads fine elsewhere.'
    } else {
      Write-Say 'skipped — audit-kit still works, it degrades to LLM-only analysis and says so'
    }
  }
}

# ── phase 5: credentials ────────────────────────────────────────────────────

function Invoke-PhaseCredentials {
  param([string[]]$Kits)
  Write-Step '5/5  Credentials — all optional'
  Write-Say 'Everything below can be skipped. The kits are usable without any of it.'
  Write-Host ''

  Write-Say 'To manage a board THROUGH THE FACTORY — Asana, Linear or Azure DevOps,'
  Write-Say 'with no repository cloned and no board credential stored here — run'
  Write-Say '/factory-connect. It needs only the token asked for below.'
  Write-Say ''
  Write-Say 'The factory engine is a separate service. If you do not use one, skip'
  Write-Say 'this — every kit works without it, and no skill will mention it.'

  # On Windows the factory is the ONLY working board path, because pm-kit's
  # direct-Asana MCP does not start. So the default flips: for anyone who took
  # pm-kit, skipping this leaves them with no board access at all.
  $default = if ($Kits -contains 'pm-kit') { 'yes' } else { 'no' }
  if ($default -eq 'yes') {
    Write-Say ''
    Write-Say 'You took pm-kit, so this is worth saying plainly: on Windows the factory'
    Write-Say 'is the only way to reach a board from here. Without a token, there is no'
    Write-Say 'board path on this machine at all.'
  }

  $prompt = 'connect this machine to a factory engine?'
  if (Get-ClaudeSettingsEnv -Name 'FACTORY_API_TOKEN') {
    Write-Ok 'FACTORY_API_TOKEN already in settings.json — keeping it'
    $prompt = 'replace the stored FACTORY_API_TOKEN?'
    $default = 'no'
  }

  Write-Host ''
  if (-not (Confirm-Step $prompt $default)) { Write-Say 'skipped — nothing here depends on it'; return }

  $t = Read-Secret 'FACTORY_API_TOKEN'
  if (-not $t) {
    # Empty input NEVER overwrites. Someone who opens the prompt and thinks
    # better of it must not lose the credential they already had.
    Write-Warn 'nothing entered — existing value left untouched'
    return
  }

  try {
    $p = Set-ClaudeSettingsEnv -Name 'FACTORY_API_TOKEN' -Value $t
    Write-Ok "saved to $p"
    Write-Warn 'RESTART Claude Code before this takes effect'
    Write-Say 'MCP servers are resolved at startup, so a token added to a running'
    Write-Say "session changes nothing — this is the most common 'the tools don't exist' report."
  } catch {
    Write-Bad "could not write settings.json: $($_.Exception.Message)"
    Add-Failure 'FACTORY_API_TOKEN (add it to ~/.claude/settings.json under env)'
  }
}

# ── -Check ──────────────────────────────────────────────────────────────────

function Show-State {
  Write-Host ''
  Write-Host 'factory-setup — state of this machine' -ForegroundColor White
  Write-Say "platform: Windows $([System.Environment]::OSVersion.Version)"
  Write-Host ''

  foreach ($t in @(
    @{ Cmd = 'winget'; Label = 'winget' }
    @{ Cmd = 'git';    Label = 'git' }
    @{ Cmd = 'gh';     Label = 'gh' }
    @{ Cmd = 'node';   Label = 'node' }
    @{ Cmd = 'claude'; Label = 'Claude Code' }
  )) {
    if (Test-Have $t.Cmd) {
      $v = switch ($t.Cmd) {
        'node'   { & node -v 2>$null }
        'claude' { Get-ClaudeVersion }
        default  { '' }
      }
      if ($t.Cmd -eq 'node' -and -not (Test-NodeOk $v)) {
        Write-Warn "$($t.Label) $v — below $($script:NODE_MAJOR)"
      } else {
        Write-Ok "$($t.Label) $v".TrimEnd()
      }
    } else {
      Write-Bad "$($t.Label) not installed"
    }
  }

  $bash = Find-GitBash
  if ($bash) { Write-Ok "Git Bash $bash" } else { Write-Bad 'Git Bash not found — .sh skills and hooks will fail' }

  if (Test-Have 'gh') {
    & gh auth status 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Ok 'GitHub authenticated' } else { Write-Bad 'GitHub not authenticated' }
  }

  if (Get-ClaudeSettingsEnv -Name 'FACTORY_API_TOKEN') { Write-Ok 'FACTORY_API_TOKEN set' }
  else { Write-Warn 'FACTORY_API_TOKEN not set (optional)' }

  if (Test-Have 'claude') {
    Write-Host ''
    Write-Host '  Plugins' -ForegroundColor White
    $list = & claude plugin list 2>&1 | Out-String
    foreach ($k in @('pm-kit', 'ship-kit', 'devhawk-kit', 'audit-kit', 'factory-kit', 'pykit')) {
      if ($list -match [regex]::Escape($k)) {
        $s = Get-KitWindowsStatus $k
        if ($s.State -eq 'ok') { Write-Ok $k } else { Write-Warn "$k — $($s.Note)" }
      }
    }
  }
  Write-Host ''
}

# ── main ────────────────────────────────────────────────────────────────────
# Everything below runs on load. The test harness cuts the file HERE and asserts
# this banner exists — a rename would otherwise run the installer during tests.

function Invoke-FactorySetup {
  if (-not $IsWindows -and $PSVersionTable.PSVersion.Major -ge 6) {
    Write-Host 'factory-setup.ps1 is for native Windows. On macOS or Linux run factory-setup.sh.' -ForegroundColor Red
    return 2
  }

  if ($Check) { Show-State; return 0 }

  Write-Host ''
  Write-Host 'factory-setup' -ForegroundColor White -NoNewline
  Write-Host ' — prerequisites, marketplace, plugins, credentials'
  Write-Say 'platform: Windows (native — no WSL)'

  # Said once, up front, because it is the honest recommendation and burying it
  # at the end would be advice nobody acts on.
  if (Test-Have 'wsl') {
    $distros = & wsl --list --quiet 2>$null
    if ($LASTEXITCODE -eq 0 -and $distros) {
      Write-Host ''
      Write-Warn 'This machine has WSL, and WSL is the better-supported path.'
      Write-Say 'Inside a distro, factory-setup.sh installs everything with no caveats —'
      Write-Say 'pm-kit''s Asana MCP works there and does not work here.'
      if (-not $Yes -and -not (Confirm-Step 'continue with the native Windows install anyway?' 'yes')) {
        Write-Say 'stopped. Open your distro and run factory-setup.sh instead.'
        return 0
      }
    }
  }

  $chosen = Request-Role
  $kits = Get-KitsForRole $chosen
  Write-Say "role: $chosen  →  $($kits -join ' ')"

  Invoke-PhasePrereqs -Kits $kits
  Invoke-PhaseGitHub
  Invoke-PhaseMarketplace
  Invoke-PhasePlugins -Kits $kits
  Invoke-PhaseCredentials -Kits $kits

  Write-Step 'Done'
  if ($script:FAILED.Count -gt 0) {
    Write-Bad 'some steps did not complete:'
    foreach ($f in $script:FAILED) { Write-Host "      - $f" }
    Write-Host ''
    Write-Say 'everything else finished. Re-running this script is safe and retries only these.'
  } else {
    Write-Ok 'everything completed'
  }

  if ($script:PATH_CHANGED) {
    Write-Host ''
    Write-Host '  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━' -ForegroundColor Yellow
    Write-Host '  Open a NEW terminal before running claude' -ForegroundColor Yellow
    Write-Host '  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━' -ForegroundColor Yellow
    Write-Host ''
    Write-Say 'PATH was refreshed inside this session, so `claude` works here. Anything'
    Write-Say 'already open — another terminal, an editor — still has the old PATH and'
    Write-Say 'will say command not found. The install is fine; that window is stale.'
  }

  Write-Host ''
  Write-Say 'Next: start Claude Code and run /help to see the skills.'
  Write-Say 'Re-run with -Check at any time to see the state of this machine.'
  Write-Host ''
  return 0
}

# Dot-sourced by the test harness with this guard set, so the functions above can
# be examined without the installer running.
if (-not $env:FACTORY_SETUP_NO_MAIN) { Invoke-FactorySetup | Out-Null }
