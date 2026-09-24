# Claude Code + OpenRouter Interactive Installer

This project installs Claude Code and configures it to use OpenRouter.

## Important: "free" mode

OpenRouter currently provides free models/routes, but that does **not** mean Claude/Anthropic models are free.

The installer therefore has two modes:

1. **Claude/Anthropic via OpenRouter**
   - Uses OpenRouter's Anthropic-compatible gateway.
   - Uses the latest Sonnet/Opus/Haiku aliases.
   - May incur API charges.

2. **OpenRouter Free Router**
   - Uses `openrouter/free`.
   - This is zero-token-cost on OpenRouter's free tier.
   - It can select non-Anthropic models.
   - Therefore this is an **experimental Claude Code compatibility mode**, not a guarantee of Claude behavior.

If your goal is specifically "Claude models for $0", this installer does not falsely promise that. Check OpenRouter's current model catalog and pricing before relying on it.

## Files

- `setup.sh` — macOS, Linux, WSL, Git Bash
- `setup.ps1` — native Windows PowerShell
- `README.md` — documentation

## macOS / Linux / WSL

```bash
chmod +x setup.sh
./setup.sh
```

Select option `5` to install and configure everything.

## Windows PowerShell

If PowerShell blocks local scripts, you can run the installer without changing the machine-wide execution policy:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\setup.ps1
```

Or start it directly after downloading:

```powershell
.\setup.ps1
```

## What gets configured

```text
OPENROUTER_API_KEY
ANTHROPIC_BASE_URL=https://openrouter.ai/api
ANTHROPIC_AUTH_TOKEN=$OPENROUTER_API_KEY
ANTHROPIC_API_KEY=""
```

The explicit empty `ANTHROPIC_API_KEY` matters because it prevents Claude Code from falling back to Anthropic authentication.

## Existing Anthropic login

If Claude Code was previously authenticated directly with Anthropic:

```text
claude
/logout
```

Then restart Claude Code after the OpenRouter environment is loaded.

## Security

Never put your own OpenRouter API key into a public repository or distribute a shared key.

The scripts store the key in a user-local file with restrictive permissions. For a public project, consider using the user's shell credential manager or an OS-specific secret store instead.

## Free-tier limits

OpenRouter's free tier has request limits. These can change, so the installer deliberately does not hard-code a daily quota.

Check OpenRouter's pricing/free-model pages before publishing claims about limits.
# DownloadClaudeCode
