#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="${SCRIPT_DIR}/templates"
DOCS_DIR="${SCRIPT_DIR}/docs"

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

# ── Helpers ───────────────────────────────────────────────────────────────────
print_step() { echo ""; echo -e "${YELLOW}${BOLD}[Step $1]${NC} $2"; echo -e "${YELLOW}$(printf '─%.0s' {1..55})${NC}"; }
ok()          { echo -e "  ${GREEN}✓${NC} $1"; }
err()         { echo -e "  ${RED}✗ ERROR:${NC} $1" >&2; }
info()        { echo -e "  ${BLUE}→${NC} $1"; }

ask() {
  local prompt="$1" default="${2:-}" var_name="$3" input
  if [[ -n "$default" ]]; then
    printf "%b%s%b [%s]: " "${BOLD}" "$prompt" "${NC}" "$default"
    IFS= read -r input
    printf -v "$var_name" '%s' "${input:-$default}"
  else
    printf "%b%s%b: " "${BOLD}" "$prompt" "${NC}"
    IFS= read -r input
    printf -v "$var_name" '%s' "$input"
  fi
}

ask_secret() {
  local prompt="$1" var_name="$2" input
  printf "%b%s%b: " "${BOLD}" "$prompt" "${NC}"
  IFS= read -rs input; echo ""
  printf -v "$var_name" '%s' "$input"
}

ask_yn() {
  local prompt="$1" var_name="$2" input
  printf "%b%s%b [y/N]: " "${BOLD}" "$prompt" "${NC}"
  IFS= read -r input
  if [[ "$input" =~ ^[Yy]$ ]]; then
    printf -v "$var_name" '%s' "true"
  else
    printf -v "$var_name" '%s' "false"
  fi
}

# Strip platform conditional blocks from a file.
# Usage: strip_block FILE PLATFORM keep|remove
strip_block() {
  local file="$1" platform="$2" action="$3"
  if [[ "$action" == "keep" ]]; then
    sed -i "/# ###BEGIN_${platform}###/d;/# ###END_${platform}###/d" "$file"
  else
    sed -i "/# ###BEGIN_${platform}###/,/# ###END_${platform}###/d" "$file"
  fi
}

process_template() {
  local src="$1" dst="$2"
  mkdir -p "$(dirname "$dst")"

  sed \
    -e "s|{{AGENT_NAME}}|${AGENT_NAME}|g" \
    -e "s|{{GH_ORG}}|${GH_ORG}|g" \
    -e "s|{{SERVER_HOST}}|${SERVER_HOST}|g" \
    -e "s|{{SERVER_USER}}|${SERVER_USER}|g" \
    -e "s|{{SERVER_PORT}}|${SERVER_PORT}|g" \
    -e "s|{{WEBHOOK_PORT}}|${WEBHOOK_PORT}|g" \
    "$src" > "$dst"

  strip_block "$dst" "SLACK"          "$([[ "$USE_SLACK" == "true" ]] && echo keep || echo remove)"
  strip_block "$dst" "DISCORD"        "$([[ "$USE_DISCORD" == "true" ]] && echo keep || echo remove)"
  strip_block "$dst" "TELEGRAM"       "$([[ "$USE_TELEGRAM" == "true" ]] && echo keep || echo remove)"
  strip_block "$dst" "GITHUB_WEBHOOK" "$([[ "$USE_GITHUB_WEBHOOK" == "true" ]] && echo keep || echo remove)"
}

# ── Step 1: Prerequisites ──────────────────────────────────────────────────────
check_prerequisites() {
  print_step 1 "Checking prerequisites"
  local missing=()

  for cmd in git gh sed; do
    if command -v "$cmd" &>/dev/null; then ok "$cmd"; else missing+=("$cmd"); err "$cmd not found"; fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    err "Please install: ${missing[*]}"; exit 1
  fi

  if ! gh auth status &>/dev/null; then
    err "GitHub CLI not authenticated. Run: gh auth login"; exit 1
  fi
  ok "GitHub CLI authenticated"
}

# ── Step 2: Agent Info ─────────────────────────────────────────────────────────
collect_agent_info() {
  print_step 2 "Agent information"

  local gh_user
  gh_user=$(gh api user --jq .login 2>/dev/null || echo "my-org")

  ask "Agent name (repo & container name)" "my-hermes" AGENT_NAME
  AGENT_NAME=$(echo "$AGENT_NAME" | tr '[:upper:]' '[:lower:]' | \
    sed 's/[^a-z0-9-]/-/g; s/--*/-/g; s/^-//; s/-$//')

  ask "GitHub org or username" "$gh_user" GH_ORG

  local default_output="$HOME/${AGENT_NAME}-config"
  ask "Output directory" "$default_output" OUTPUT_DIR
  OUTPUT_DIR="${OUTPUT_DIR/#\~/$HOME}"

  if [[ -d "$OUTPUT_DIR" ]]; then
    err "Directory already exists: $OUTPUT_DIR"
    local overwrite
    ask_yn "Overwrite?" overwrite
    if [[ "$overwrite" != "true" ]]; then exit 1; fi
    rm -rf "$OUTPUT_DIR"
  fi
}

# ── Step 3: Messaging Platform ────────────────────────────────────────────────
collect_platforms() {
  print_step 3 "Messaging platform (at least one required)"
  USE_SLACK=false; USE_DISCORD=false; USE_TELEGRAM=false

  ask_yn "Enable Slack?" USE_SLACK
  ask_yn "Enable Discord?" USE_DISCORD
  ask_yn "Enable Telegram?" USE_TELEGRAM

  if [[ "$USE_SLACK" != "true" && "$USE_DISCORD" != "true" && "$USE_TELEGRAM" != "true" ]]; then
    err "At least one messaging platform must be selected."; exit 1
  fi

  if [[ "$USE_SLACK" == "true" ]]; then
    echo ""; info "Slack credentials:"
    ask_secret "  SLACK_BOT_TOKEN (xoxb-...)" SLACK_BOT_TOKEN
    ask_secret "  SLACK_APP_TOKEN (xapp-...)" SLACK_APP_TOKEN
    ask "  SLACK_ALLOWED_USERS (comma-separated user IDs)" "" SLACK_ALLOWED_USERS
  fi

  if [[ "$USE_DISCORD" == "true" ]]; then
    echo ""; info "Discord credentials:"
    ask_secret "  DISCORD_BOT_TOKEN" DISCORD_BOT_TOKEN
    ask "  DISCORD_GUILD_ID" "" DISCORD_GUILD_ID
  fi

  if [[ "$USE_TELEGRAM" == "true" ]]; then
    echo ""; info "Telegram credentials:"
    ask_secret "  TELEGRAM_BOT_TOKEN" TELEGRAM_BOT_TOKEN
    ask "  TELEGRAM_ALLOWED_USERS (comma-separated, optional)" "" TELEGRAM_ALLOWED_USERS
  fi
}

# ── Step 4: Optional Integrations ─────────────────────────────────────────────
collect_integrations() {
  print_step 4 "Optional integrations"
  USE_GITHUB_WEBHOOK=false
  ask_yn "Enable GitHub webhook (PR reviewer, issue automation)?" USE_GITHUB_WEBHOOK

  if [[ "$USE_GITHUB_WEBHOOK" == "true" ]]; then
    ask "  Webhook port" "8644" WEBHOOK_PORT
    ask_secret "  GITHUB_WEBHOOK_SECRET" GITHUB_WEBHOOK_SECRET
    ask_secret "  GH_TOKEN (GitHub personal access token)" GH_TOKEN
  else
    WEBHOOK_PORT="8644"
    GITHUB_WEBHOOK_SECRET=""
    GH_TOKEN=""
  fi
}

# ── Step 5: Anthropic API Key ──────────────────────────────────────────────────
collect_api_keys() {
  print_step 5 "Anthropic API key"
  ask_secret "ANTHROPIC_API_KEY (sk-ant-...)" ANTHROPIC_API_KEY
}

# ── Step 6: Server Info ────────────────────────────────────────────────────────
collect_server_info() {
  print_step 6 "Server information (for CI/CD deploy)"
  ask "Server hostname" "your-server.example.com" SERVER_HOST
  ask "Server username" "ubuntu" SERVER_USER
  ask "SSH port" "22" SERVER_PORT
}

# ── Step 7: Generate Files ─────────────────────────────────────────────────────
generate_env_example() {
  local f="$OUTPUT_DIR/.env.example"
  {
    echo "# Hermes Agent — Environment Variables"
    echo "# Copy this to .env on your server and fill in the values"
    echo "# NEVER commit .env to git"
    echo ""
    echo "# ── Anthropic ──────────────────────────────────────────"
    echo "ANTHROPIC_API_KEY="
  } > "$f"

  if [[ "$USE_SLACK" == "true" ]]; then
    printf '\n# ── Slack ──────────────────────────────────────────────\n' >> "$f"
    printf 'SLACK_BOT_TOKEN=\nSLACK_APP_TOKEN=\nSLACK_ALLOWED_USERS=\nSLACK_REQUIRE_MENTION=true\n' >> "$f"
  fi
  if [[ "$USE_DISCORD" == "true" ]]; then
    printf '\n# ── Discord ────────────────────────────────────────────\n' >> "$f"
    printf 'DISCORD_BOT_TOKEN=\nDISCORD_GUILD_ID=\n' >> "$f"
  fi
  if [[ "$USE_TELEGRAM" == "true" ]]; then
    printf '\n# ── Telegram ───────────────────────────────────────────\n' >> "$f"
    printf 'TELEGRAM_BOT_TOKEN=\nTELEGRAM_ALLOWED_USERS=\n' >> "$f"
  fi
  if [[ "$USE_GITHUB_WEBHOOK" == "true" ]]; then
    printf '\n# ── GitHub ─────────────────────────────────────────────\n' >> "$f"
    printf 'GITHUB_WEBHOOK_SECRET=\nGH_TOKEN=\n' >> "$f"
  fi
}

generate_dot_env() {
  local f="$OUTPUT_DIR/.env"
  {
    echo "# ${AGENT_NAME} — generated by setup.sh — KEEP SECRET"
    echo "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}"
  } > "$f"

  [[ "$USE_SLACK" == "true" ]] && {
    echo "SLACK_BOT_TOKEN=${SLACK_BOT_TOKEN}"
    echo "SLACK_APP_TOKEN=${SLACK_APP_TOKEN}"
    echo "SLACK_ALLOWED_USERS=${SLACK_ALLOWED_USERS}"
    echo "SLACK_REQUIRE_MENTION=true"
  } >> "$f"

  [[ "$USE_DISCORD" == "true" ]] && {
    echo "DISCORD_BOT_TOKEN=${DISCORD_BOT_TOKEN}"
    echo "DISCORD_GUILD_ID=${DISCORD_GUILD_ID}"
  } >> "$f"

  [[ "$USE_TELEGRAM" == "true" ]] && {
    echo "TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}"
    echo "TELEGRAM_ALLOWED_USERS=${TELEGRAM_ALLOWED_USERS:-}"
  } >> "$f"

  [[ "$USE_GITHUB_WEBHOOK" == "true" ]] && {
    echo "GITHUB_WEBHOOK_SECRET=${GITHUB_WEBHOOK_SECRET}"
    echo "GH_TOKEN=${GH_TOKEN}"
  } >> "$f"

  chmod 600 "$f"
}

generate_files() {
  print_step 7 "Generating files"
  mkdir -p "$OUTPUT_DIR"

  process_template "$TEMPLATE_DIR/config.yaml.tmpl"                    "$OUTPUT_DIR/config.yaml"
  ok "config.yaml"

  process_template "$TEMPLATE_DIR/docker-compose.yml.tmpl"             "$OUTPUT_DIR/docker-compose.yml"
  ok "docker-compose.yml"

  process_template "$TEMPLATE_DIR/SOUL.md.tmpl"                        "$OUTPUT_DIR/SOUL.md"
  ok "SOUL.md"

  process_template "$TEMPLATE_DIR/.gitignore.tmpl"                     "$OUTPUT_DIR/.gitignore"
  ok ".gitignore"

  process_template "$TEMPLATE_DIR/.github/workflows/deploy.yml.tmpl"   "$OUTPUT_DIR/.github/workflows/deploy.yml"
  ok ".github/workflows/deploy.yml"

  generate_env_example; ok ".env.example"
  generate_dot_env;     ok ".env  (local only — gitignored)"

  mkdir -p "$OUTPUT_DIR/skills" "$OUTPUT_DIR/memories"
  touch "$OUTPUT_DIR/skills/.gitkeep" "$OUTPUT_DIR/memories/.gitkeep"
  ok "skills/ and memories/"

  mkdir -p "$OUTPUT_DIR/docs"
  cp "$DOCS_DIR/server-setup.md" "$OUTPUT_DIR/docs/server-setup.md"
  ok "docs/server-setup.md"
}

# ── Step 8: GitHub Repo ────────────────────────────────────────────────────────
create_github_repo() {
  print_step 8 "Creating GitHub repository"

  local repo="${GH_ORG}/${AGENT_NAME}-config"

  cd "$OUTPUT_DIR"
  git init -b main -q
  git add .
  git commit -q -m "feat: initial ${AGENT_NAME} agent config

Generated by hermes-agent-template/setup.sh"

  info "Creating private repo: ${repo}"
  gh repo create "$repo" --private --source=. --push \
    --description "Hermes agent config for ${AGENT_NAME}"

  ok "https://github.com/${repo}"
}

# ── Step 9: Next Steps ─────────────────────────────────────────────────────────
print_next_steps() {
  local repo="${GH_ORG}/${AGENT_NAME}-config"

  echo ""
  echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}${BOLD}║  Setup complete!                                  ║${NC}"
  echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  Config repo : ${BOLD}https://github.com/${repo}${NC}"
  echo -e "  Local dir   : ${BOLD}${OUTPUT_DIR}${NC}"
  echo ""
  echo -e "${YELLOW}${BOLD}Next — complete server setup:${NC}"
  echo ""
  echo -e "  1. Add GitHub Actions secrets:"
  echo -e "     ${BLUE}gh secret set SERVER_HOST   --body \"${SERVER_HOST}\"  --repo ${repo}${NC}"
  echo -e "     ${BLUE}gh secret set SERVER_USER   --body \"${SERVER_USER}\"  --repo ${repo}${NC}"
  echo -e "     ${BLUE}gh secret set SERVER_PORT   --body \"${SERVER_PORT}\"  --repo ${repo}${NC}"
  echo -e "     ${BLUE}gh secret set SERVER_SSH_KEY < ~/.ssh/YOUR_DEPLOY_KEY --repo ${repo}${NC}"
  echo ""
  echo -e "  2. Transfer .env to server (contains your secrets):"
  echo -e "     ${BLUE}scp ${OUTPUT_DIR}/.env ${SERVER_USER}@${SERVER_HOST}:/opt/${AGENT_NAME}-config/.env${NC}"
  echo ""
  echo -e "  3. Full guide: ${BOLD}${OUTPUT_DIR}/docs/server-setup.md${NC}"
  echo ""
}

# ── Main ───────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BLUE}${BOLD}╔═══════════════════════════════════════════╗${NC}"
echo -e "${BLUE}${BOLD}║   Hermes Agent Setup                      ║${NC}"
echo -e "${BLUE}${BOLD}╚═══════════════════════════════════════════╝${NC}"

check_prerequisites
collect_agent_info
collect_platforms
collect_integrations
collect_api_keys
collect_server_info
generate_files
create_github_repo
print_next_steps
