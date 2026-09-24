#!/usr/bin/env bash
# Claude Code + OpenRouter interactive setup
# Supports macOS, Linux and WSL. On native Windows use setup.ps1
# (this script can hand off to it when run from Git Bash).
#
# Design notes
#  * Every user supplies their OWN OpenRouter key. Nothing is embedded here.
#  * The key is stored in a chmod 600 file, never in your shell profile or a .env.
#  * A separate launcher (`claude-or`) runs Claude Code through OpenRouter, so your
#    normal `claude` (Anthropic login) is left alone unless you opt in.

set -o pipefail

CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/claude-openrouter"
ENV_FILE="$CONF_DIR/env"
BIN_DIR="$HOME/.local/bin"
WRAPPER="$BIN_DIR/claude-or"
OR_BASE_URL="https://openrouter.ai/api"
OR_MODELS_URL="https://openrouter.ai/api/v1/models"
OR_KEY_URL="https://openrouter.ai/api/v1/key"
MARK_BEGIN="# >>> claude-openrouter >>>"
MARK_END="# <<< claude-openrouter <<<"

if [ -t 1 ]; then
  B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; N=$'\033[0m'
else
  B=; G=; Y=; R=; N=
fi
ok()    { printf '%s✓%s %s\n' "$G" "$N" "$*"; }
warn()  { printf '%s!%s %s\n' "$Y" "$N" "$*"; }
err()   { printf '%s✗%s %s\n' "$R" "$N" "$*" >&2; }
info()  { printf '%s\n' "$*"; }
pause() { printf '\nPress Enter to continue...'; read -r _; }

ask_yn() { # ask_yn "question" Y|N   (second arg = default)
  local p="[Y/n]" d="y" a
  if [ "${2:-Y}" = "N" ]; then p="[y/N]"; d="n"; fi
  read -r -p "$1 $p " a
  a="${a:-$d}"
  [[ "$a" =~ ^[Yy] ]]
}

# ───────────────────────── OS detection ─────────────────────────
detect_os() {
  case "$(uname -s)" in
    Darwin) OS="macOS" ;;
    Linux)  if grep -qi microsoft /proc/version 2>/dev/null; then OS="WSL"; else OS="Linux"; fi ;;
    MINGW*|MSYS*|CYGWIN*) OS="Windows" ;;
    *) OS="Unknown" ;;
  esac
}

banner() {
  clear 2>/dev/null || true
  printf '%s╔══════════════════════════════════════════╗\n' "$B"
  printf '║     Claude Code + OpenRouter Setup       ║\n'
  printf '╚══════════════════════════════════════════╝%s\n' "$N"
  info "Detected OS: $OS"
  if [ "$OS" = "WSL" ]; then
    info "(WSL: this installs the Linux build inside WSL. For native Windows, run setup.ps1 in PowerShell.)"
  fi
}

hand_off_windows() {
  local here ps1
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  ps1="$here/setup.ps1"
  warn "Native Windows detected (Git Bash/MSYS). Use the PowerShell script instead."
  if [ -f "$ps1" ] && command -v powershell.exe >/dev/null 2>&1; then
    if ask_yn "Launch setup.ps1 now?" Y; then
      powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$ps1" 2>/dev/null || echo "$ps1")"
    fi
  else
    info "Open PowerShell and run:  powershell -ExecutionPolicy Bypass -File .\\setup.ps1"
  fi
}

# ───────────────────────── Install ─────────────────────────
install_claude() {
  if command -v claude >/dev/null 2>&1; then
    ok "Claude Code already installed: $(claude --version 2>/dev/null | head -1)"
    ask_yn "Reinstall / update anyway?" N || return 0
  fi
  command -v curl >/dev/null 2>&1 || { err "curl is required but not found."; return 1; }
  info "This runs Anthropic's official native installer:"
  info "  curl -fsSL https://claude.ai/install.sh | bash"
  ask_yn "Continue?" Y || return 0
  if curl -fsSL https://claude.ai/install.sh | bash; then
    export PATH="$BIN_DIR:$PATH"; hash -r 2>/dev/null
    if command -v claude >/dev/null 2>&1; then
      ok "Claude Code installed: $(claude --version 2>/dev/null | head -1)"
    else
      warn "Installed, but 'claude' isn't on PATH yet. Open a new terminal, or add $BIN_DIR to PATH."
    fi
  else
    err "Installer failed. Check your network, or see https://docs.claude.com for alternatives (e.g. npm)."
    return 1
  fi
}

# ───────────────────────── OpenRouter helpers ─────────────────────────
validate_key() { # returns 1 only if OpenRouter explicitly rejects the key
  local code
  # The key goes to curl via stdin config so it never appears in `ps` output.
  code="$(printf 'header = "Authorization: Bearer %s"\n' "$1" \
    | curl -s -o /dev/null -w '%{http_code}' --max-time 15 -K - "$OR_KEY_URL" 2>/dev/null)"
  case "$code" in
    200)     ok "OpenRouter accepted the key." ;;
    401|403) err "OpenRouter rejected this key (HTTP $code)."; return 1 ;;
    *)       warn "Couldn't verify the key (HTTP ${code:-no response}); continuing." ;;
  esac
}

# Prints "model-id<TAB>context_length" for models that are $0 AND support tool calling.
fetch_free_models() {
  local json
  json="$(curl -fsS --max-time 20 "$OR_MODELS_URL" 2>/dev/null)" || return 1
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$json" | jq -r '
      .data[]
      | select((.pricing.prompt|tostring)=="0" and (.pricing.completion|tostring)=="0")
      | select((.supported_parameters // []) | index("tools"))
      | "\(.id)\t\(.context_length // 0)"'
  elif command -v python3 >/dev/null 2>&1; then
    printf '%s' "$json" | python3 -c '
import sys, json
def zero(v):
    try: return float(v) == 0.0
    except (TypeError, ValueError): return False
for m in json.load(sys.stdin).get("data", []):
    p = m.get("pricing") or {}
    if zero(p.get("prompt")) and zero(p.get("completion")) and "tools" in (m.get("supported_parameters") or []):
        print("%s\t%s" % (m["id"], m.get("context_length") or 0))'
  else
    return 1
  fi
}

valid_model_id() { [[ "$1" =~ ^[][A-Za-z0-9._/:~@+-]+$ ]]; }

pick_free_model() {
  info "Fetching OpenRouter's current free models that support tool calling..."
  local list; list="$(fetch_free_models | sort -t $'\t' -k2,2 -nr | head -15)"
  if [ -z "$list" ]; then
    warn "Couldn't fetch the list (needs network plus jq or python3). Enter a model ID manually."
    pick_manual_model; return $?
  fi
  local -a ids=(); local i=1 id ctx
  echo
  while IFS=$'\t' read -r id ctx; do
    ids+=("$id")
    printf '  [%2d] %-55s %sk context\n' "$i" "$id" "$(( ${ctx:-0} / 1000 ))"
    i=$((i+1))
  done <<< "$list"
  echo "  [ m] Enter a model ID manually"
  local sel; read -r -p "Select: " sel
  if [ "$sel" = "m" ] || [ "$sel" = "M" ]; then pick_manual_model; return $?; fi
  if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le "${#ids[@]}" ]; then
    MODEL="${ids[$((sel-1))]}"; MODE="free"
  else
    err "Invalid selection."; return 1
  fi
}

pick_manual_model() {
  read -r -p "Model ID (e.g. vendor/model:free): " MODEL
  valid_model_id "$MODEL" || { err "That doesn't look like a valid model ID."; return 1; }
  MODE="custom"
}

choose_model() {
  echo; info "${B}Model selection${N}"
  echo "  [1] Free model (choose from OpenRouter's current free list)"
  echo "  [2] Enter a model ID manually"
  echo "  [3] Anthropic Claude via OpenRouter (paid credits, best compatibility)"
  local m; read -r -p "Select [1]: " m; m="${m:-1}"
  case "$m" in
    1) pick_free_model ;;
    2) pick_manual_model ;;
    3) MODE="anthropic"; MODEL="" ;;
    *) err "Invalid selection."; return 1 ;;
  esac
}

# ───────────────────────── Config writing ─────────────────────────
write_config() {
  mkdir -p "$CONF_DIR" "$BIN_DIR" || return 1
  chmod 700 "$CONF_DIR"
  (
    umask 077
    {
      echo "# Generated by setup.sh. Contains your OpenRouter key: do not commit or share."
      echo "export ANTHROPIC_BASE_URL='$OR_BASE_URL'"
      echo "export ANTHROPIC_AUTH_TOKEN='$API_KEY'"
      echo 'export ANTHROPIC_API_KEY=""   # must be explicitly empty'
      if [ "$MODE" = "anthropic" ]; then
        cat <<'EOF'
export CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1
export ANTHROPIC_DEFAULT_FABLE_MODEL='~anthropic/claude-fable-latest[1m]'
export ANTHROPIC_DEFAULT_OPUS_MODEL='~anthropic/claude-opus-latest[1m]'
export ANTHROPIC_DEFAULT_SONNET_MODEL='~anthropic/claude-sonnet-latest[1m]'
export ANTHROPIC_DEFAULT_HAIKU_MODEL='~anthropic/claude-haiku-latest'
export CLAUDE_CODE_SUBAGENT_MODEL='~anthropic/claude-opus-latest[1m]'
EOF
      else
        for v in FABLE OPUS SONNET HAIKU; do
          echo "export ANTHROPIC_DEFAULT_${v}_MODEL='$MODEL'"
        done
        echo "export CLAUDE_CODE_SUBAGENT_MODEL='$MODEL'"
      fi
    } > "$ENV_FILE"
  ) || return 1
  chmod 600 "$ENV_FILE"

  cat > "$WRAPPER" <<'EOF'
#!/usr/bin/env bash
# Runs Claude Code through OpenRouter without touching your normal `claude` setup.
ENV_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/claude-openrouter/env"
if [ ! -r "$ENV_FILE" ]; then
  echo "Missing $ENV_FILE. Run setup.sh and choose 'Configure OpenRouter'." >&2
  exit 1
fi
. "$ENV_FILE"
exec claude "$@"
EOF
  chmod 755 "$WRAPPER"
}

profile_file() {
  case "$(basename "${SHELL:-}")" in
    zsh)  echo "$HOME/.zshrc" ;;
    bash) if [ "$OS" = "macOS" ]; then echo "$HOME/.bash_profile"; else echo "$HOME/.bashrc"; fi ;;
    fish) echo "" ;;
    *)    echo "$HOME/.profile" ;;
  esac
}

remove_profile_block() {
  local f="$1"
  [ -f "$f" ] && grep -qF "$MARK_BEGIN" "$f" || return 0
  awk -v b="$MARK_BEGIN" -v e="$MARK_END" '$0==b{s=1;next} $0==e{s=0;next} !s' "$f" > "$f.tmp" \
    && cat "$f.tmp" > "$f"; rm -f "$f.tmp"
}

update_profile_block() { # update_profile_block add_path(0/1) make_default(0/1)
  local f; f="$(profile_file)"
  if [ -z "$f" ]; then
    warn "fish shell detected: skipping profile edits (the env file uses POSIX syntax). Use 'claude-or'."
    return 0
  fi
  remove_profile_block "$f"
  [ "$1" = 1 ] || [ "$2" = 1 ] || return 0
  {
    echo "$MARK_BEGIN"
    [ "$1" = 1 ] && echo 'export PATH="$HOME/.local/bin:$PATH"'
    [ "$2" = 1 ] && echo "[ -r \"$ENV_FILE\" ] && . \"$ENV_FILE\""
    echo "$MARK_END"
  } >> "$f"
  ok "Updated $f (open a new terminal to apply)."
}

configure_openrouter() {
  echo; info "${B}OpenRouter configuration${N}"; info "────────────────────────"
  info "Create a key at https://openrouter.ai/settings/keys (use your own, never share it)."
  local key
  read -r -s -p "Enter your OpenRouter API key (input hidden): " key; echo
  key="$(printf '%s' "$key" | tr -d '[:space:]')"
  [ -n "$key" ] || { err "No key entered."; return 1; }
  [[ "$key" =~ ^[A-Za-z0-9_-]+$ ]] || { err "Key contains unexpected characters."; return 1; }
  [[ "$key" == sk-or-* ]] || warn "Key doesn't start with 'sk-or-'. Double-check it."
  if ! validate_key "$key"; then ask_yn "Save it anyway?" N || return 1; fi
  API_KEY="$key"

  choose_model || return 1
  write_config || { err "Could not write configuration."; return 1; }
  ok "Configuration saved to $ENV_FILE (permissions 600)"
  ok "Launcher created: $WRAPPER"
  [ "$MODE" = "anthropic" ] && ok "Model: Anthropic Claude via OpenRouter" || ok "Model: $MODEL"

  local add_path=0 make_default=0
  case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) warn "$BIN_DIR is not on your PATH."
       ask_yn "Add it to your shell profile?" Y && add_path=1 ;;
  esac
  echo
  info "Optional: make plain 'claude' ALWAYS use OpenRouter (adds one line to your profile)."
  info "If you say no, use 'claude-or' for OpenRouter and 'claude' stays on your Anthropic login."
  ask_yn "Make OpenRouter the default for 'claude'?" N && make_default=1
  update_profile_block "$add_path" "$make_default"
  unset API_KEY

  echo
  info "${B}Next steps${N}"
  info "  1. If you ever logged in to Claude Code with an Anthropic account, run /logout once inside it,"
  info "     then quit and relaunch (a cached login can cause auth-conflict / model-not-found errors)."
  info "  2. Start it:   ${B}claude-or${N}   (or ${B}claude${N} if you chose the default option)"
  info "  3. Inside Claude Code, run ${B}/status${N} and confirm:"
  info "       Auth token: ANTHROPIC_AUTH_TOKEN"
  info "       Anthropic base URL: $OR_BASE_URL"
  echo
  if [ "$MODE" != "anthropic" ]; then
    warn "Free models: tight rate/daily limits that OpenRouter can change, and free endpoints may log"
    warn "prompts. Don't send secrets or private code. OpenRouter says Claude Code is only guaranteed"
    warn "with Anthropic's first-party models; other models can misbehave with tool calls."
  else
    warn "Anthropic models on OpenRouter are billed against your OpenRouter credits."
  fi
}

# ───────────────────────── Check / reset ─────────────────────────
check_installation() {
  echo; info "${B}Installation check${N}"; info "───────────────────"
  if command -v claude >/dev/null 2>&1; then
    ok "claude found: $(command -v claude)  ($(claude --version 2>/dev/null | head -1))"
  else
    err "claude not found on PATH (choose 'Install Claude Code')."
  fi

  if [ -f "$ENV_FILE" ]; then
    local perms; perms="$(stat -c '%a' "$ENV_FILE" 2>/dev/null || stat -f '%Lp' "$ENV_FILE" 2>/dev/null)"
    ok "OpenRouter config present: $ENV_FILE (perms $perms)"
    [ "$perms" = "600" ] || warn "Expected permissions 600. Fix with: chmod 600 \"$ENV_FILE\""
    local tok mdl
    tok="$(. "$ENV_FILE"; printf '%s' "$ANTHROPIC_AUTH_TOKEN")"
    mdl="$(. "$ENV_FILE"; printf '%s' "${ANTHROPIC_DEFAULT_SONNET_MODEL:-}")"
    info "  Key: …${tok: -4}   Sonnet-class model: ${mdl:-n/a}"
    validate_key "$tok" || true
  else
    warn "No OpenRouter config yet (choose 'Configure OpenRouter')."
  fi

  [ -x "$WRAPPER" ] && ok "Launcher present: $WRAPPER" || warn "Launcher 'claude-or' not found."
  if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    warn "Your current shell has a real ANTHROPIC_API_KEY set. 'claude-or' overrides it, but plain 'claude' will use it."
  fi

  if [ -x "$WRAPPER" ] && command -v claude >/dev/null 2>&1; then
    echo
    if ask_yn "Run a quick live test through OpenRouter? (uses a tiny amount of quota/credits)" N; then
      "$WRAPPER" -p "Reply with the single word: OK" || err "Live test failed. Check /status, your key and model."
    fi
  fi
  info "Inside Claude Code, /status should show 'Auth token: ANTHROPIC_AUTH_TOKEN' and base URL $OR_BASE_URL."
}

reset_config() {
  echo
  warn "This removes the OpenRouter config, the 'claude-or' launcher, and any profile lines this script added."
  info "It does NOT uninstall Claude Code itself."
  ask_yn "Continue?" N || return 0
  rm -f "$ENV_FILE" "$WRAPPER"
  rmdir "$CONF_DIR" 2>/dev/null
  local f; f="$(profile_file)"; [ -n "$f" ] && remove_profile_block "$f"
  ok "OpenRouter configuration removed."
  info "To remove Claude Code: delete ~/.local/bin/claude and ~/.local/share/claude (native install)."
}

# ───────────────────────── Main ─────────────────────────
main_menu() {
  while true; do
    banner
    cat <<EOF

  [1] Install Claude Code
  [2] Configure OpenRouter
  [3] Check installation
  [4] Reset / remove OpenRouter config
  [5] Exit

EOF
    local c; read -r -p "Select: " c
    case "$c" in
      1) install_claude;        pause ;;
      2) configure_openrouter;  pause ;;
      3) check_installation;    pause ;;
      4) reset_config;          pause ;;
      5|q|Q) echo "Bye!"; exit 0 ;;
      *) warn "Please choose 1-5."; sleep 1 ;;
    esac
  done
}

detect_os
case "$OS" in
  Windows) banner; hand_off_windows; exit 0 ;;
  Unknown) err "Unsupported OS: $(uname -s)"; exit 1 ;;
esac
main_menu
