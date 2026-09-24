$ErrorActionPreference = "Stop"

# Claude Code + OpenRouter interactive installer for Windows PowerShell

$AppDir = Join-Path $HOME ".claude-openrouter"
$ConfigFile = Join-Path $AppDir "config.ps1"

function Write-Ok($Message) {
    Write-Host "✓ $Message" -ForegroundColor Green
}

function Write-Warn($Message) {
    Write-Host "! $Message" -ForegroundColor Yellow
}

function Install-Claude {
    if (Get-Command claude -ErrorAction SilentlyContinue) {
        Write-Ok "Claude Code is already installed."
        claude --version
        return
    }

    Write-Host "Installing Claude Code..."
    irm https://claude.ai/install.ps1 | iex

    $ClaudePath = Join-Path $HOME ".local\bin"
    if (Test-Path $ClaudePath) {
        $env:Path = "$ClaudePath;$env:Path"
    }

    if (Get-Command claude -ErrorAction SilentlyContinue) {
        Write-Ok "Claude Code installed."
        claude --version
    } else {
        Write-Warn "Claude was installed, but this PowerShell session may need to be restarted."
    }
}

function Configure-OpenRouter {
    New-Item -ItemType Directory -Force -Path $AppDir | Out-Null

    Write-Host ""
    Write-Host "OpenRouter configuration"
    Write-Host "Create/get your key at: https://openrouter.ai/keys"
    Write-Host ""

    $SecureKey = Read-Host "OpenRouter API key (sk-or-...)" -AsSecureString
    $BSTR = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureKey)
    try {
        $ApiKey = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($BSTR)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
    }

    if ([string]::IsNullOrWhiteSpace($ApiKey)) {
        throw "No API key entered."
    }

    if (-not $ApiKey.StartsWith("sk-or-")) {
        Write-Warn "The key does not start with sk-or-. Continuing anyway."
    }

    Write-Host ""
    Write-Host "Choose a mode:"
    Write-Host "  1) Claude/Anthropic via OpenRouter (may cost money)"
    Write-Host "  2) OpenRouter free router (experimental with Claude Code)"
    $Mode = Read-Host "Choice [1-2, default 2]"
    if ([string]::IsNullOrWhiteSpace($Mode)) { $Mode = "2" }

    switch ($Mode) {
        "1" { $Model = "~anthropic/claude-sonnet-latest" }
        "2" { $Model = "openrouter/free" }
        default { throw "Invalid choice." }
    }

    @"
`$env:OPENROUTER_API_KEY = "$ApiKey"
`$env:ANTHROPIC_BASE_URL = "https://openrouter.ai/api"
`$env:ANTHROPIC_AUTH_TOKEN = "`$env:OPENROUTER_API_KEY"
`$env:ANTHROPIC_API_KEY = ""

`$env:ANTHROPIC_DEFAULT_SONNET_MODEL = "$Model"
`$env:ANTHROPIC_DEFAULT_OPUS_MODEL = "$Model"
`$env:ANTHROPIC_DEFAULT_HAIKU_MODEL = "$Model"
"@ | Set-Content -Path $ConfigFile -Encoding UTF8

    # Restrict file ACL to current user.
    icacls $ConfigFile /inheritance:r | Out-Null
    icacls $ConfigFile /grant:r "$env:USERNAME:(R,W)" | Out-Null

    . $ConfigFile

    Write-Ok "OpenRouter configuration saved to $ConfigFile"
    Write-Warn "The API key is stored in a user-only configuration file."
}

function Configure-PowerShellProfile {
    if (-not (Test-Path $PROFILE)) {
        New-Item -ItemType File -Force -Path $PROFILE | Out-Null
    }

    $Marker = "# >>> claude-code-openrouter >>>"

    if ((Get-Content $PROFILE -Raw) -like "*$Marker*") {
        Write-Ok "PowerShell profile is already configured."
        return
    }

    Add-Content $PROFILE @"

$Marker
if (Test-Path "$ConfigFile") { . "$ConfigFile" }
# <<< claude-code-openrouter <<<
"@

    Write-Ok "Added OpenRouter configuration to $PROFILE"
    Write-Host "Restart PowerShell or run: . `$PROFILE"
}

function Verify-Setup {
    Write-Host ""
    Write-Host "Verification"

    if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
        $ClaudePath = Join-Path $HOME ".local\bin"
        if (Test-Path $ClaudePath) {
            $env:Path = "$ClaudePath;$env:Path"
        }
    }

    if (Get-Command claude -ErrorAction SilentlyContinue) {
        Write-Ok "Claude Code installed"
        claude --version
    } else {
        Write-Warn "Claude command is not available in this session."
    }

    if ($env:ANTHROPIC_BASE_URL -eq "https://openrouter.ai/api") {
        Write-Ok "OpenRouter endpoint configured"
    }

    if ([string]::IsNullOrEmpty($env:ANTHROPIC_API_KEY)) {
        Write-Ok "Anthropic API key explicitly empty"
    }

    if ($env:OPENROUTER_API_KEY) {
        Write-Ok "OpenRouter API key loaded"
    }

    Write-Host ""
    Write-Host "If Claude Code has an existing Anthropic login, start:"
    Write-Host "  claude"
    Write-Host "then run:"
    Write-Host "  /logout"
}

function Main-Menu {
    while ($true) {
        Write-Host ""
        Write-Host "========================================"
        Write-Host "      Claude Code + OpenRouter"
        Write-Host "========================================"
        Write-Host "  1) Install Claude Code"
        Write-Host "  2) Configure OpenRouter"
        Write-Host "  3) Configure PowerShell profile"
        Write-Host "  4) Verify setup"
        Write-Host "  5) Install + configure everything"
        Write-Host "  6) Show current configuration"
        Write-Host "  7) Exit"
        Write-Host ""

        $Choice = Read-Host "Select [1-7]"

        switch ($Choice) {
            "1" { Install-Claude }
            "2" { Configure-OpenRouter }
            "3" { Configure-PowerShellProfile }
            "4" { Verify-Setup }
            "5" {
                Install-Claude
                Configure-OpenRouter
                Configure-PowerShellProfile
                Verify-Setup
            }
            "6" {
                if (Test-Path $ConfigFile) {
                    Write-Host "Config: $ConfigFile"
                    Write-Host "Model configuration present."
                } else {
                    Write-Warn "No configuration found."
                }
            }
            "7" { return }
            default { Write-Warn "Invalid option." }
        }
    }
}

Main-Menu
