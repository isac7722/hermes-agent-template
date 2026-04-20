# hermes-agent-template

A template for spinning up a new [Hermes](https://github.com/NousResearch/hermes-agent) AI agent with Docker + GitHub CI/CD in minutes.

## What you get

Running `setup.sh` generates a private GitHub repo (`{your-org}/{agent-name}-config`) containing:

```
{agent-name}-config/
├── config.yaml            # Hermes settings (platform-specific sections auto-configured)
├── SOUL.md                # Agent persona — customize freely
├── docker-compose.yml     # Server deployment config
├── .env.example           # Secret key names (no values)
├── .gitignore             # Excludes .env, state files, etc.
├── skills/                # Add custom skills here
├── memories/              # Agent memory files
├── docs/server-setup.md   # Step-by-step server setup guide
└── .github/workflows/
    └── deploy.yml         # Push to main → auto-deploy to server
```

A `.env` file with your secrets is also generated locally (gitignored) for you to transfer to the server.

## Prerequisites

- `git`, `gh` (GitHub CLI), `sed`
- `gh auth login` completed

## Usage

```bash
git clone https://github.com/aptimizer-co/hermes-agent-template.git
cd hermes-agent-template
bash setup.sh
```

The script will ask you:

| Prompt | Example |
|---|---|
| Agent name | `my-hermes` |
| GitHub org/user | `my-org` |
| Messaging platform | Slack / Discord / Telegram (pick ≥1) |
| GitHub webhook? | y/n |
| Anthropic API key | `sk-ant-...` |
| Server hostname | `server.example.com` |

Then it creates `my-org/my-hermes-config` on GitHub and pushes everything.

## After setup

Follow `docs/server-setup.md` in your generated repo to:
1. Add GitHub Actions secrets for SSH deploy
2. Transfer `.env` to the server
3. Clone the config repo and run `docker compose up -d`

From that point, any `git push` to `main` auto-deploys via GitHub Actions.

## Architecture

```
Local machine: setup.sh
  └── generates: {agent-name}-config/ → gh repo create → push

GitHub: {org}/{agent-name}-config (private)
  └── .github/workflows/deploy.yml
      └── on push: SSH → server → git pull → docker compose up

Server: /opt/{agent-name}-config/
  └── docker-compose.yml
      ├── bind mount: config.yaml, SOUL.md, skills/, memories/
      └── named volume: state.db, sessions/, cache/ (persisted)
```

## Customization

| File | Purpose |
|---|---|
| `SOUL.md` | Agent personality and domain expertise |
| `config.yaml` | Model selection, platform settings, agent behavior |
| `skills/` | Add custom skill directories (`SKILL.md` + supporting files) |
| `docker-compose.yml` | Ports, volumes, resource limits |

## Platform notes

**Slack**: Requires a Slack App with Socket Mode enabled. Bot scopes: `chat:write`, `im:history`, `channels:history`.

**Discord**: Requires a Discord Bot with Message Content Intent enabled.

**Telegram**: Requires a bot created via [@BotFather](https://t.me/botfather).

**GitHub webhook**: Requires a GitHub App or webhook configured to send PR/issue events to `http://your-server:8644`.
