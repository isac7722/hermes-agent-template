#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="${SCRIPT_DIR}/templates"
DOCS_DIR="${SCRIPT_DIR}/docs"

# When run via curl (bash <(curl ...)), BASH_SOURCE[0] is /dev/stdin — templates/ won't exist.
if [[ ! -d "$TEMPLATE_DIR" ]]; then
  _CLONE_DIR="/tmp/hermes-agent-template-$$"
  echo "Downloading template files..."
  git clone --depth=1 --quiet https://github.com/isac7722/hermes-agent-template.git "$_CLONE_DIR"
  trap 'rm -rf "$_CLONE_DIR"' EXIT
  TEMPLATE_DIR="${_CLONE_DIR}/templates"
  DOCS_DIR="${_CLONE_DIR}/docs"
fi

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

# ── Basic helpers ─────────────────────────────────────────────────────────────
print_step() { echo ""; echo -e "${YELLOW}${BOLD}[Step $1]${NC} $2"; echo -e "${YELLOW}$(printf '─%.0s' {1..55})${NC}"; }
ok()          { echo -e "  ${GREEN}✓${NC} $1"; }
warn()        { echo -e "  ${YELLOW}⚠${NC}  $1"; }
err()         { echo -e "  ${RED}✗ ERROR:${NC} $1" >&2; }
info()        { echo -e "  ${BLUE}→${NC} $1"; }

ask() {
  local prompt="$1" default="${2:-}" var_name="$3" input
  if [[ -n "$default" ]]; then
    printf "%b%s%b [%s]: " "${BOLD}" "$prompt" "${NC}" "$default"
    read -r input
    input="${input#"${input%%[![:space:]]*}"}"  # ltrim
    input="${input%"${input##*[![:space:]]}"}"  # rtrim
    printf -v "$var_name" '%s' "${input:-$default}"
  else
    printf "%b%s%b: " "${BOLD}" "$prompt" "${NC}"
    read -r input
    input="${input#"${input%%[![:space:]]*}"}"
    input="${input%"${input##*[![:space:]]}"}"
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
  [[ "$input" =~ ^[Yy]$ ]] && printf -v "$var_name" '%s' "true" || printf -v "$var_name" '%s' "false"
}

# ── Port helpers ───────────────────────────────────────────────────────────────
port_in_use() {
  ss -tlnp 2>/dev/null | awk '{print $4}' | grep -q ":${1}$" 2>/dev/null
}

# Check default port; if in use suggest nearby free ports, then ask
ask_port() {
  local prompt="$1" default="$2" var_name="$3"

  if port_in_use "$default"; then
    warn "기본 포트 ${default}가 사용 중입니다."
    local suggestions=()
    for p in $(seq $(( default + 1 )) $(( default + 20 ))); do
      port_in_use "$p" || { suggestions+=("$p"); [[ ${#suggestions[@]} -ge 3 ]] && break; }
    done
    [[ ${#suggestions[@]} -gt 0 ]] && \
      info "사용 가능한 포트: ${suggestions[*]}"
    default="${suggestions[0]:-$(( default + 1 ))}"
  else
    ok "기본 포트 ${default} 사용 가능"
  fi

  while true; do
    ask "$prompt" "$default" "$var_name"
    local port="${!var_name}"
    if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1024 || port > 65535 )); then
      warn "유효하지 않은 포트입니다. 1024–65535 범위로 입력해주세요."; continue
    fi
    if port_in_use "$port"; then
      warn "포트 ${port}는 사용 중입니다. 다른 포트를 입력해주세요."
    else
      ok "포트 ${port} 선택됨"
      break
    fi
  done
}

# ── Token validation ───────────────────────────────────────────────────────────
# Usage: ask_validated_secret "prompt" VAR_NAME "prefix_pattern" "hint"
ask_validated_secret() {
  local prompt="$1" var_name="$2" pattern="$3" hint="$4"
  while true; do
    ask_secret "$prompt" "$var_name"
    local val="${!var_name}"
    if [[ -z "$val" ]]; then
      warn "값이 비어있습니다. 다시 입력해주세요."; continue
    fi
    if [[ -n "$pattern" ]] && ! echo "$val" | grep -qE "^($pattern)"; then
      warn "형식이 올바르지 않습니다. 예상 형식: ${hint}"
      local force
      ask_yn "  그래도 이 값을 사용할까요?" force
      [[ "$force" == "true" ]] && break
    else
      break
    fi
  done
}

# Ask for secret; if empty, auto-generate with given command
ask_secret_or_generate() {
  local prompt="$1" var_name="$2" gen_cmd="$3"
  printf "%b%s%b %b(Enter to auto-generate)%b: " "${BOLD}" "$prompt" "${NC}" "${DIM}" "${NC}"
  IFS= read -rs input; echo ""
  if [[ -z "$input" ]]; then
    input=$(eval "$gen_cmd")
    ok "자동 생성됨: ${DIM}${input:0:16}...${NC}"
  fi
  printf -v "$var_name" '%s' "$input"
}

# ── Template processing ────────────────────────────────────────────────────────
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

# ── Platform setup guides ──────────────────────────────────────────────────────
guide_box() {
  local title="$1" width=56
  local pad=$(( (width - ${#title}) / 2 ))
  echo ""
  echo -e "  ${BLUE}$(printf '─%.0s' {1..56})${NC}"
  printf "  ${BLUE}%${pad}s${BOLD}%s${NC}${BLUE}%${pad}s${NC}\n" "" "$title" ""
  echo -e "  ${BLUE}$(printf '─%.0s' {1..56})${NC}"
  echo ""
}

guide_slack() {
  guide_box "Slack App 설정 가이드"
  echo -e "  ${BOLD}1.${NC} https://api.slack.com/apps → Create New App → From scratch"
  echo -e "  ${BOLD}2.${NC} 앱 이름 입력 → workspace 선택"
  echo -e "  ${BOLD}3.${NC} Features → Socket Mode → Enable"
  echo -e "     App-Level Token 생성 (scope: connections:write) → 복사"
  echo -e "     ${BLUE}→ 이것이 SLACK_APP_TOKEN (xapp-...)${NC}"
  echo -e "  ${BOLD}4.${NC} OAuth & Permissions → Bot Token Scopes 추가:"
  echo -e "     chat:write  im:history  channels:history  app_mentions:read"
  echo -e "  ${BOLD}5.${NC} Install to Workspace → Bot User OAuth Token (xoxb-...) 복사"
  echo -e "     ${BLUE}→ 이것이 SLACK_BOT_TOKEN${NC}"
  echo -e "  ${BOLD}6.${NC} App Home → Messages 탭에서 DM 허용 체크"
  echo -e "  ${BOLD}7.${NC} User ID: Slack → 프로필 → ⋮ → 멤버 ID 복사"
  echo ""
  printf "  준비됐으면 Enter 눌러 계속..."; IFS= read -r _
}

guide_discord() {
  guide_box "Discord Bot 설정 가이드"
  echo -e "  ${BOLD}1.${NC} https://discord.com/developers/applications → New Application"
  echo -e "  ${BOLD}2.${NC} Bot 탭 → Token 복사 (Reset Token)"
  echo -e "     ${BLUE}→ 이것이 DISCORD_BOT_TOKEN${NC}"
  echo -e "  ${BOLD}3.${NC} Privileged Gateway Intents → Message Content Intent → ON"
  echo -e "  ${BOLD}4.${NC} OAuth2 → URL Generator:"
  echo -e "     Scopes: bot   /   Permissions: Send Messages, Read Messages"
  echo -e "  ${BOLD}5.${NC} 생성된 URL → 서버에 봇 초대"
  echo -e "  ${BOLD}6.${NC} 서버 ID: 설정 → 고급 → 개발자 모드 ON"
  echo -e "     서버 이름 우클릭 → 서버 ID 복사"
  echo -e "     ${BLUE}→ 이것이 DISCORD_GUILD_ID${NC}"
  echo ""
  printf "  준비됐으면 Enter 눌러 계속..."; IFS= read -r _
}

guide_telegram() {
  guide_box "Telegram Bot 설정 가이드"
  echo -e "  ${BOLD}1.${NC} Telegram에서 @BotFather 검색 → 대화 시작"
  echo -e "     ${BLUE}https://t.me/botfather${NC}"
  echo -e "  ${BOLD}2.${NC} /newbot 입력"
  echo -e "  ${BOLD}3.${NC} 봇 표시 이름 입력 (예: My Assistant)"
  echo -e "  ${BOLD}4.${NC} 봇 username (예: myassistant_bot)  ← _bot으로 끝나야 함"
  echo -e "  ${BOLD}5.${NC} 발급된 토큰 복사 (예: 123456789:ABCdef...)"
  echo -e "     ${BLUE}→ 이것이 TELEGRAM_BOT_TOKEN${NC}"
  echo -e "  ${BOLD}6.${NC} User ID: @userinfobot 에게 아무 메시지 전송"
  echo -e "     ${BLUE}→ 이것이 TELEGRAM_ALLOWED_USERS${NC}"
  echo ""
  printf "  준비됐으면 Enter 눌러 계속..."; IFS= read -r _
}

guide_github_webhook() {
  guide_box "GitHub Webhook 설정 가이드"
  echo -e "  ${BOLD}1.${NC} GitHub → Settings → Developer settings → Personal access tokens"
  echo -e "     → Generate new token (classic)   Scopes: repo, read:org"
  echo -e "     ${BLUE}→ 이것이 GH_TOKEN (ghp_...)${NC}"
  echo -e "  ${BOLD}2.${NC} Webhook Secret: 아무 값이나 가능 (또는 Enter로 자동 생성)"
  echo -e "     ${DIM}직접 생성하려면: openssl rand -hex 32${NC}"
  echo -e "     ${BLUE}→ 이것이 GITHUB_WEBHOOK_SECRET${NC}"
  echo -e "  ${BOLD}3.${NC} 서버 시작 후 repo → Settings → Webhooks 등록:"
  echo -e "     Payload URL: http://YOUR_SERVER:PORT/webhooks/..."
  echo -e "     Secret: 위에서 설정한 값"
  echo -e "     Events: Pull requests, Issues"
  echo ""
  printf "  준비됐으면 Enter 눌러 계속..."; IFS= read -r _
}

# ── Step 1: Prerequisites ──────────────────────────────────────────────────────
check_prerequisites() {
  print_step 1 "Checking prerequisites"
  local missing=()
  for cmd in git gh sed openssl; do
    command -v "$cmd" &>/dev/null && ok "$cmd" || { missing+=("$cmd"); err "$cmd not found"; }
  done
  [[ ${#missing[@]} -gt 0 ]] && { err "Please install: ${missing[*]}"; exit 1; }
  gh auth status &>/dev/null || { err "GitHub CLI not authenticated. Run: gh auth login"; exit 1; }
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
    warn "Directory already exists: $OUTPUT_DIR"
    local overwrite
    ask_yn "Overwrite?" overwrite
    [[ "$overwrite" != "true" ]] && exit 1
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
    guide_slack
    echo -e "  ${BOLD}Slack credentials:${NC}"
    ask_validated_secret "  SLACK_BOT_TOKEN" SLACK_BOT_TOKEN "xoxb-" "xoxb-..."
    ask_validated_secret "  SLACK_APP_TOKEN" SLACK_APP_TOKEN "xapp-" "xapp-..."
    ask "  SLACK_ALLOWED_USERS (쉼표 구분 User ID)" "" SLACK_ALLOWED_USERS
  fi

  if [[ "$USE_DISCORD" == "true" ]]; then
    guide_discord
    echo -e "  ${BOLD}Discord credentials:${NC}"
    ask_secret "  DISCORD_BOT_TOKEN" DISCORD_BOT_TOKEN
    ask "  DISCORD_GUILD_ID" "" DISCORD_GUILD_ID
  fi

  if [[ "$USE_TELEGRAM" == "true" ]]; then
    guide_telegram
    echo -e "  ${BOLD}Telegram credentials:${NC}"
    ask_validated_secret "  TELEGRAM_BOT_TOKEN" TELEGRAM_BOT_TOKEN "[0-9]+:[A-Za-z0-9_-]+" "123456789:ABCdef..."
    ask "  TELEGRAM_ALLOWED_USERS (쉼표 구분 User ID, 선택)" "" TELEGRAM_ALLOWED_USERS
  fi
}

# ── Step 4: Optional Integrations ─────────────────────────────────────────────
collect_integrations() {
  print_step 4 "Optional integrations"
  USE_GITHUB_WEBHOOK=false
  ask_yn "Enable GitHub webhook (PR reviewer, issue automation)?" USE_GITHUB_WEBHOOK

  if [[ "$USE_GITHUB_WEBHOOK" == "true" ]]; then
    guide_github_webhook
    echo -e "  ${BOLD}GitHub webhook credentials:${NC}"
    ask_port "  Webhook port" "8644" WEBHOOK_PORT
    ask_secret_or_generate "  GITHUB_WEBHOOK_SECRET" GITHUB_WEBHOOK_SECRET "openssl rand -hex 32"
    ask_validated_secret "  GH_TOKEN (GitHub personal access token)" GH_TOKEN "ghp_|github_pat_" "ghp_... 또는 github_pat_..."
  else
    WEBHOOK_PORT="8644"
    GITHUB_WEBHOOK_SECRET=""
    GH_TOKEN=""
  fi
}

# ── Step 5: Anthropic API Key ──────────────────────────────────────────────────
collect_api_keys() {
  print_step 5 "Anthropic API key"
  ask_validated_secret "ANTHROPIC_API_KEY" ANTHROPIC_API_KEY "sk-ant-" "sk-ant-api03-..."
}

# ── Step 6: Server Info ────────────────────────────────────────────────────────
collect_server_info() {
  print_step 6 "Server information (for CI/CD deploy)"
  ask "Server hostname" "your-server.example.com" SERVER_HOST
  ask "Server username" "ubuntu" SERVER_USER
  ask "SSH port" "22" SERVER_PORT
}

# ── Step 7: Summary & Confirmation ────────────────────────────────────────────
show_summary() {
  print_step 7 "Summary — please review before creating repo"

  local platforms=""
  [[ "$USE_SLACK" == "true" ]]    && platforms+="Slack "
  [[ "$USE_DISCORD" == "true" ]]  && platforms+="Discord "
  [[ "$USE_TELEGRAM" == "true" ]] && platforms+="Telegram"

  echo ""
  echo -e "  ${BOLD}Agent name   :${NC} ${AGENT_NAME}"
  echo -e "  ${BOLD}GitHub repo  :${NC} ${GH_ORG}/${AGENT_NAME}-config (private)"
  echo -e "  ${BOLD}Output dir   :${NC} ${OUTPUT_DIR}"
  echo -e "  ${BOLD}Platforms    :${NC} ${platforms}"
  [[ "$USE_GITHUB_WEBHOOK" == "true" ]] && \
    echo -e "  ${BOLD}Webhook port :${NC} ${WEBHOOK_PORT}"
  echo -e "  ${BOLD}Server       :${NC} ${SERVER_USER}@${SERVER_HOST}:${SERVER_PORT}"
  echo ""
  echo -e "  ${DIM}(Secrets are collected but not shown)${NC}"
  echo ""
  local confirm
  ask_yn "계속 진행할까요?" confirm
  [[ "$confirm" != "true" ]] && { echo "Aborted."; exit 0; }
}

# ── Step 8: Generate Files ─────────────────────────────────────────────────────
generate_env_example() {
  local f="$OUTPUT_DIR/.env.example"
  { echo "# Hermes Agent — Environment Variables"
    echo "# Copy this to .env on your server and fill in the values"
    echo "# NEVER commit .env to git"
    echo ""
    echo "# ── Anthropic ──────────────────────────────────────────"
    echo "ANTHROPIC_API_KEY="; } > "$f"
  [[ "$USE_SLACK" == "true" ]] && {
    printf '\n# ── Slack ──────────────────────────────────────────────\n'
    printf 'SLACK_BOT_TOKEN=\nSLACK_APP_TOKEN=\nSLACK_ALLOWED_USERS=\nSLACK_REQUIRE_MENTION=true\n'; } >> "$f"
  [[ "$USE_DISCORD" == "true" ]] && {
    printf '\n# ── Discord ────────────────────────────────────────────\n'
    printf 'DISCORD_BOT_TOKEN=\nDISCORD_GUILD_ID=\n'; } >> "$f"
  [[ "$USE_TELEGRAM" == "true" ]] && {
    printf '\n# ── Telegram ───────────────────────────────────────────\n'
    printf 'TELEGRAM_BOT_TOKEN=\nTELEGRAM_ALLOWED_USERS=\n'; } >> "$f"
  [[ "$USE_GITHUB_WEBHOOK" == "true" ]] && {
    printf '\n# ── GitHub ─────────────────────────────────────────────\n'
    printf 'GITHUB_WEBHOOK_SECRET=\nGH_TOKEN=\n'; } >> "$f"
}

generate_dot_env() {
  local f="$OUTPUT_DIR/.env"
  { echo "# ${AGENT_NAME} — generated by setup.sh — KEEP SECRET"
    echo "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}"; } > "$f"
  [[ "$USE_SLACK" == "true" ]] && {
    echo "SLACK_BOT_TOKEN=${SLACK_BOT_TOKEN}"
    echo "SLACK_APP_TOKEN=${SLACK_APP_TOKEN}"
    echo "SLACK_ALLOWED_USERS=${SLACK_ALLOWED_USERS}"
    echo "SLACK_REQUIRE_MENTION=true"; } >> "$f"
  [[ "$USE_DISCORD" == "true" ]] && {
    echo "DISCORD_BOT_TOKEN=${DISCORD_BOT_TOKEN}"
    echo "DISCORD_GUILD_ID=${DISCORD_GUILD_ID}"; } >> "$f"
  [[ "$USE_TELEGRAM" == "true" ]] && {
    echo "TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}"
    echo "TELEGRAM_ALLOWED_USERS=${TELEGRAM_ALLOWED_USERS:-}"; } >> "$f"
  [[ "$USE_GITHUB_WEBHOOK" == "true" ]] && {
    echo "GITHUB_WEBHOOK_SECRET=${GITHUB_WEBHOOK_SECRET}"
    echo "GH_TOKEN=${GH_TOKEN}"; } >> "$f"
  chmod 600 "$f"
}

generate_files() {
  print_step 8 "Generating files"
  mkdir -p "$OUTPUT_DIR"
  process_template "$TEMPLATE_DIR/config.yaml.tmpl"                  "$OUTPUT_DIR/config.yaml";              ok "config.yaml"
  process_template "$TEMPLATE_DIR/docker-compose.yml.tmpl"           "$OUTPUT_DIR/docker-compose.yml";       ok "docker-compose.yml"
  process_template "$TEMPLATE_DIR/SOUL.md.tmpl"                      "$OUTPUT_DIR/SOUL.md";                  ok "SOUL.md"
  process_template "$TEMPLATE_DIR/.gitignore.tmpl"                   "$OUTPUT_DIR/.gitignore";               ok ".gitignore"
  process_template "$TEMPLATE_DIR/.github/workflows/deploy.yml.tmpl" "$OUTPUT_DIR/.github/workflows/deploy.yml"; ok ".github/workflows/deploy.yml"
  generate_env_example; ok ".env.example"
  generate_dot_env;     ok ".env  (local only — gitignored)"
  mkdir -p "$OUTPUT_DIR/skills" "$OUTPUT_DIR/memories"
  touch "$OUTPUT_DIR/skills/.gitkeep" "$OUTPUT_DIR/memories/.gitkeep"
  ok "skills/ and memories/"
  mkdir -p "$OUTPUT_DIR/docs"
  cp "$DOCS_DIR/server-setup.md" "$OUTPUT_DIR/docs/server-setup.md"; ok "docs/server-setup.md"
}

# ── Step 9: GitHub Repo ────────────────────────────────────────────────────────
create_github_repo() {
  print_step 9 "Creating GitHub repository"
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

# ── Step 10: Register GitHub Actions Secrets ───────────────────────────────────
register_github_secrets() {
  print_step 10 "Registering GitHub Actions secrets"
  local repo="${GH_ORG}/${AGENT_NAME}-config"

  gh secret set SERVER_HOST --body "$SERVER_HOST" --repo "$repo" && ok "SERVER_HOST"
  gh secret set SERVER_USER --body "$SERVER_USER" --repo "$repo" && ok "SERVER_USER"
  gh secret set SERVER_PORT --body "$SERVER_PORT" --repo "$repo" && ok "SERVER_PORT"

  echo ""
  echo -e "  ${YELLOW}SSH 배포 키가 필요합니다. (GitHub Actions가 서버에 접속할 때 사용)${NC}"
  echo -e "  ${DIM}없다면 Enter를 눌러 건너뛰고 나중에 추가할 수 있습니다.${NC}"
  ask "  SSH private key 경로" "" _SSH_KEY_PATH

  if [[ -n "$_SSH_KEY_PATH" ]]; then
    _SSH_KEY_PATH="${_SSH_KEY_PATH/#\~/$HOME}"
    if [[ -f "$_SSH_KEY_PATH" ]]; then
      gh secret set SERVER_SSH_KEY < "$_SSH_KEY_PATH" --repo "$repo" && ok "SERVER_SSH_KEY"
    else
      warn "파일을 찾을 수 없습니다: ${_SSH_KEY_PATH} (나중에 수동 등록 필요)"
    fi
  else
    warn "SERVER_SSH_KEY 건너뜀 — 배포 전에 수동 등록 필요"
    echo -e "     ${DIM}gh secret set SERVER_SSH_KEY < ~/.ssh/deploy_key --repo ${repo}${NC}"
  fi
}

# ── Final: Next Steps ──────────────────────────────────────────────────────────
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
  echo -e "${YELLOW}${BOLD}남은 작업 — 서버 초기화:${NC}"
  echo ""
  echo -e "  1. .env를 서버로 전송 (시크릿 포함, git에는 없음):"
  echo -e "     ${BLUE}scp ${OUTPUT_DIR}/.env ${SERVER_USER}@${SERVER_HOST}:/opt/${AGENT_NAME}-config/.env${NC}"
  echo ""
  echo -e "  2. 서버에서 config repo clone 및 실행:"
  echo -e "     ${BLUE}git clone git@github.com:${repo}.git /opt/${AGENT_NAME}-config${NC}"
  echo -e "     ${BLUE}cd /opt/${AGENT_NAME}-config && docker compose up -d${NC}"
  echo ""
  echo -e "  3. 상세 가이드: ${BOLD}${OUTPUT_DIR}/docs/server-setup.md${NC}"
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
show_summary
generate_files
create_github_repo
register_github_secrets
print_next_steps
