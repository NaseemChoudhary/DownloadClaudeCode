<#
  Claude Code + OpenRouter interactive setup for native Windows (PowerShell 5.1+ / 7+).

  Run:  powershell -ExecutionPolicy Bypass -File .\setup.ps1

  Design notes
   * Every user supplies their OWN OpenRouter key. Nothing is embedded here.
   * The key is stored encrypted with Windows DPAPI (readable only by your Windows user
     on this machine), not in plain text, not in a .env file, not in the registry.
   * A launcher (claude-or) runs Claude Code through OpenRouter, so plain `claude`
     (Anthropic login) is untouched unless you opt in.
#>

$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$Base       = Join-Path $env:USERPROFILE '.claude-openrouter'
$KeyFile    = Join-Path $Base 'key.enc'
$CfgFile    = Join-Path $Base 'config.json'
$OrBaseUrl  = 'https://openrouter.ai/api'
$OrModels   = 'https://openrouter.ai/api/v1/models'
$OrKeyUrl   = 'https://openrouter.ai/api/v1/key'

function Ok($m)   { Write-Host "[OK] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "[!]  $m" -ForegroundColor Yellow }
function Err($m)  { Write-Host "[X]  $m" -ForegroundColor Red }
function Pause-Menu { Write-Host ''; Read-Host 'Press Enter to continue' | Out-Null }
function Ask-YN($q, [bool]$default = $true) {
    $hint = if ($default) { '[Y/n]' } else { '[y/N]' }
    $a = Read-Host "$q $hint"
    if ([string]::IsNullOrWhiteSpace($a)) { return $default }
    return $a -match '^[Yy]'
}
function Refresh-Path {
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                [Environment]::GetEnvironmentVariable('Path', 'User')
}
function Plain-FromSecure([System.Security.SecureString]$s) {
    $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
}

function Show-Banner {
    Clear-Host
    Write-Host '+------------------------------------------+' -ForegroundColor Cyan
    Write-Host '|     Claude Code + OpenRouter Setup       |' -ForegroundColor Cyan
    Write-Host '+------------------------------------------+' -ForegroundColor Cyan
    Write-Host "Detected: Windows (PowerShell $($PSVersionTable.PSVersion))"
}

# ------------------------- Install -------------------------
function Install-Claude {
    if (Get-Command claude -ErrorAction SilentlyContinue) {
        Ok "Claude Code already installed: $(& claude --version 2>$null)"
        if (-not (Ask-YN 'Reinstall / update anyway?' $false)) { return }
    }
    Write-Host "This runs Anthropic's official native installer:"
    Write-Host '  irm https://claude.ai/install.ps1 | iex'
    if (-not (Ask-YN 'Continue?' $true)) { return }
    try {
        Invoke-RestMethod https://claude.ai/install.ps1 | Invoke-Expression
        Refresh-Path
        if (Get-Command claude -ErrorAction SilentlyContinue) {
            Ok "Claude Code installed: $(& claude --version 2>$null)"
        } else {
            Warn "Installed, but 'claude' isn't on PATH yet. Open a new PowerShell window."
        }
        if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
            Warn 'Git for Windows was not found. If Claude Code complains about Git Bash, install it from https://git-scm.com'
        }
    } catch { Err "Installer failed: $($_.Exception.Message)" }
}

# ------------------------- OpenRouter helpers -------------------------
function Test-Key([string]$key) { # $true ok, $false rejected, $null unknown
    try {
        Invoke-RestMethod -Uri $OrKeyUrl -Headers @{ Authorization = "Bearer $key" } -TimeoutSec 15 | Out-Null
        Ok 'OpenRouter accepted the key.'; return $true
    } catch {
        $code = $null
        try { $code = [int]$_.Exception.Response.StatusCode } catch {}
        if ($code -eq 401 -or $code -eq 403) { Err "OpenRouter rejected this key (HTTP $code)."; return $false }
        Warn 'Could not verify the key; continuing.'; return $null
    }
}

function Get-FreeModels {
    $r = Invoke-RestMethod -Uri $OrModels -TimeoutSec 20
    $r.data | Where-Object {
        $_.pricing -and
        [double]$_.pricing.prompt -eq 0 -and [double]$_.pricing.completion -eq 0 -and
        ($_.supported_parameters -contains 'tools')
    } | Sort-Object { [int]$_.context_length } -Descending | Select-Object -First 15
}

function Test-ModelId([string]$m) { $m -match '^[A-Za-z0-9._/:~@+\[\]-]+$' }

function Read-ManualModel {
    $m = (Read-Host 'Model ID (e.g. vendor/model:free)').Trim()
    if (-not (Test-ModelId $m)) { Err "That doesn't look like a valid model ID."; return $null }
    return @{ Mode = 'custom'; Model = $m }
}

function Select-Model {
    Write-Host ''
    Write-Host 'Model selection' -ForegroundColor Cyan
    Write-Host "  [1] Free model (choose from OpenRouter's current free list)"
    Write-Host '  [2] Enter a model ID manually'
    Write-Host '  [3] Anthropic Claude via OpenRouter (paid credits, best compatibility)'
    $c = Read-Host 'Select [1]'; if (-not $c) { $c = '1' }
    switch ($c) {
        '1' {
            Write-Host "Fetching OpenRouter's current free models that support tool calling..."
            try { $list = @(Get-FreeModels) } catch { $list = @() }
            if ($list.Count -eq 0) { Warn "Couldn't fetch the list. Enter a model ID manually."; return Read-ManualModel }
            for ($i = 0; $i -lt $list.Count; $i++) {
                '  [{0,2}] {1,-55} {2}k context' -f ($i + 1), $list[$i].id, [int]([int]$list[$i].context_length / 1000) | Write-Host
            }
            Write-Host '  [ m] Enter a model ID manually'
            $s = Read-Host 'Select'
            if ($s -eq 'm') { return Read-ManualModel }
            if ($s -match '^\d+$' -and [int]$s -ge 1 -and [int]$s -le $list.Count) {
                return @{ Mode = 'free'; Model = $list[[int]$s - 1].id }
            }
            Err 'Invalid selection.'; return $null
        }
        '2' { return Read-ManualModel }
        '3' { return @{ Mode = 'anthropic'; Model = '' } }
        default { Err 'Invalid selection.'; return $null }
    }
}

# ------------------------- Configure -------------------------
$LauncherPs1 = @'
# Runs Claude Code through OpenRouter without touching your normal `claude` setup.
$ErrorActionPreference = 'Stop'
$cfg = Get-Content (Join-Path $PSScriptRoot 'config.json') -Raw | ConvertFrom-Json
$secure = (Get-Content (Join-Path $PSScriptRoot 'key.enc') -Raw).Trim() | ConvertTo-SecureString
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
try { $key = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
$env:ANTHROPIC_BASE_URL   = 'https://openrouter.ai/api'
$env:ANTHROPIC_AUTH_TOKEN = $key
Remove-Item Env:ANTHROPIC_API_KEY -ErrorAction SilentlyContinue   # must not hold a real Anthropic key
foreach ($p in $cfg.env.PSObject.Properties) { Set-Item -Path ("Env:" + $p.Name) -Value $p.Value }
& claude @args
exit $LASTEXITCODE
'@

$LauncherCmd = @'
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0claude-or.ps1" %*
'@

function Build-EnvMap($sel) {
    $env = [ordered]@{}
    if ($sel.Mode -eq 'anthropic') {
        $env['CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY'] = '1'
        $env['ANTHROPIC_DEFAULT_FABLE_MODEL']  = '~anthropic/claude-fable-latest[1m]'
        $env['ANTHROPIC_DEFAULT_OPUS_MODEL']   = '~anthropic/claude-opus-latest[1m]'
        $env['ANTHROPIC_DEFAULT_SONNET_MODEL'] = '~anthropic/claude-sonnet-latest[1m]'
        $env['ANTHROPIC_DEFAULT_HAIKU_MODEL']  = '~anthropic/claude-haiku-latest'
        $env['CLAUDE_CODE_SUBAGENT_MODEL']     = '~anthropic/claude-opus-latest[1m]'
    } else {
        foreach ($v in 'FABLE', 'OPUS', 'SONNET', 'HAIKU') { $env["ANTHROPIC_DEFAULT_${v}_MODEL"] = $sel.Model }
        $env['CLAUDE_CODE_SUBAGENT_MODEL'] = $sel.Model
    }
    return $env
}

function Set-UserPath([string]$dir, [bool]$add) {
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $parts = @($user -split ';' | Where-Object { $_ -and ($_.TrimEnd('\') -ne $dir.TrimEnd('\')) })
    if ($add) { $parts += $dir }
    [Environment]::SetEnvironmentVariable('Path', ($parts -join ';'), 'User')
    Refresh-Path
}

function Configure-OpenRouter {
    Write-Host ''
    Write-Host 'OpenRouter configuration' -ForegroundColor Cyan
    Write-Host 'Create a key at https://openrouter.ai/settings/keys (use your own, never share it).'
    $secure = Read-Host 'Enter your OpenRouter API key (input hidden)' -AsSecureString
    $key = (Plain-FromSecure $secure).Trim()
    if (-not $key) { Err 'No key entered.'; return }
    if ($key -notmatch '^[A-Za-z0-9_-]+$') { Err 'Key contains unexpected characters.'; return }
    if (-not $key.StartsWith('sk-or-')) { Warn "Key doesn't start with 'sk-or-'. Double-check it." }
    if ((Test-Key $key) -eq $false) { if (-not (Ask-YN 'Save it anyway?' $false)) { return } }

    $sel = Select-Model
    if (-not $sel) { return }

    New-Item -ItemType Directory -Force -Path $Base | Out-Null
    (ConvertTo-SecureString $key -AsPlainText -Force | ConvertFrom-SecureString) | Set-Content -Path $KeyFile -Encoding ASCII
    @{ mode = $sel.Mode; model = $sel.Model; env = (Build-EnvMap $sel) } | ConvertTo-Json -Depth 4 | Set-Content -Path $CfgFile -Encoding UTF8
    Set-Content -Path (Join-Path $Base 'claude-or.ps1') -Value $LauncherPs1 -Encoding UTF8
    Set-Content -Path (Join-Path $Base 'claude-or.cmd') -Value $LauncherCmd -Encoding ASCII
    $key = $null

    Ok "Configuration saved to $Base (key encrypted with Windows DPAPI)"
    if ($sel.Mode -eq 'anthropic') { Ok 'Model: Anthropic Claude via OpenRouter' } else { Ok "Model: $($sel.Model)" }

    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (($userPath -split ';') -notcontains $Base) {
        if (Ask-YN "Add $Base to your user PATH so 'claude-or' works anywhere?" $true) {
            Set-UserPath $Base $true; Ok "Added to PATH (open a new terminal to apply)."
        }
    }

    Write-Host ''
    Write-Host "Optional: make plain 'claude' ALWAYS use OpenRouter." -ForegroundColor Cyan
    Write-Host "On Windows this means setting user environment variables. The key would then be stored"
    Write-Host "in plain text in your user environment, so it is NOT enabled by this script."
    Write-Host "Recommended: keep using 'claude-or' for OpenRouter and 'claude' for your Anthropic login."

    Write-Host ''
    Write-Host 'Next steps' -ForegroundColor Cyan
    Write-Host "  1. If you ever logged in to Claude Code with an Anthropic account, run /logout once inside it,"
    Write-Host "     then quit and relaunch (a cached login can cause auth-conflict / model-not-found errors)."
    Write-Host "  2. Start it:  claude-or"
    Write-Host "  3. Inside Claude Code run /status and confirm:"
    Write-Host "       Auth token: ANTHROPIC_AUTH_TOKEN"
    Write-Host "       Anthropic base URL: $OrBaseUrl"
    Write-Host ''
    if ($sel.Mode -ne 'anthropic') {
        Warn 'Free models: tight rate/daily limits that OpenRouter can change, and free endpoints may log'
        Warn "prompts. Don't send secrets or private code. OpenRouter says Claude Code is only guaranteed"
        Warn "with Anthropic's first-party models; other models can misbehave with tool calls."
    } else {
        Warn 'Anthropic models on OpenRouter are billed against your OpenRouter credits.'
    }
}

# ------------------------- Check / reset -------------------------
function Check-Installation {
    Write-Host ''
    Write-Host 'Installation check' -ForegroundColor Cyan
    $c = Get-Command claude -ErrorAction SilentlyContinue
    if ($c) { Ok "claude found: $($c.Source)  ($(& claude --version 2>$null))" }
    else    { Err "claude not found on PATH (choose 'Install Claude Code')." }

    if ((Test-Path $KeyFile) -and (Test-Path $CfgFile)) {
        $cfg = Get-Content $CfgFile -Raw | ConvertFrom-Json
        Ok "OpenRouter config present: $Base"
        $model = if ($cfg.mode -eq 'anthropic') { 'Anthropic Claude (paid)' } else { $cfg.model }
        Write-Host "  Model: $model"
        try {
            $k = Plain-FromSecure ((Get-Content $KeyFile -Raw).Trim() | ConvertTo-SecureString)
            Write-Host "  Key: ...$($k.Substring([Math]::Max(0, $k.Length - 4)))"
            Test-Key $k | Out-Null
        } catch { Err 'Could not decrypt the saved key (was it created by another Windows user/machine?). Re-run Configure.' }
    } else { Warn "No OpenRouter config yet (choose 'Configure OpenRouter')." }

    if (Test-Path (Join-Path $Base 'claude-or.ps1')) { Ok 'Launcher present: claude-or' } else { Warn "Launcher 'claude-or' not found." }
    if ($env:ANTHROPIC_API_KEY) { Warn "Your session has a real ANTHROPIC_API_KEY. 'claude-or' clears it, but plain 'claude' will use it." }

    if ((Test-Path (Join-Path $Base 'claude-or.ps1')) -and $c) {
        if (Ask-YN 'Run a quick live test through OpenRouter? (uses a tiny amount of quota/credits)' $false) {
            & (Join-Path $Base 'claude-or.ps1') -p 'Reply with the single word: OK'
        }
    }
    Write-Host "Inside Claude Code, /status should show 'Auth token: ANTHROPIC_AUTH_TOKEN' and base URL $OrBaseUrl."
}

function Reset-Config {
    Write-Host ''
    Warn "This removes the OpenRouter config, the encrypted key, and the 'claude-or' launcher."
    Write-Host 'It does NOT uninstall Claude Code itself.'
    if (-not (Ask-YN 'Continue?' $false)) { return }
    Set-UserPath $Base $false
    if (Test-Path $Base) { Remove-Item -Recurse -Force $Base }
    Ok 'OpenRouter configuration removed.'
}

# ------------------------- Main -------------------------
while ($true) {
    Show-Banner
    Write-Host ''
    Write-Host '  [1] Install Claude Code'
    Write-Host '  [2] Configure OpenRouter'
    Write-Host '  [3] Check installation'
    Write-Host '  [4] Reset / remove OpenRouter config'
    Write-Host '  [5] Exit'
    Write-Host ''
    switch (Read-Host 'Select') {
        '1' { Install-Claude;        Pause-Menu }
        '2' { Configure-OpenRouter;  Pause-Menu }
        '3' { Check-Installation;    Pause-Menu }
        '4' { Reset-Config;          Pause-Menu }
        '5' { Write-Host 'Bye!'; exit 0 }
        default { Warn 'Please choose 1-5.'; Start-Sleep 1 }
    }
}
