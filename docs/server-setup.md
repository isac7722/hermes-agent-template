# Server Setup Guide

After running `setup.sh` locally, follow these steps to complete the server setup.

## Prerequisites

- Server with Docker + Docker Compose installed
- `gh` CLI authenticated (for managing secrets)
- SSH access to the server

---

## Step 1: Add GitHub Actions Secrets

```bash
REPO="YOUR_ORG/YOUR_AGENT_NAME-config"

gh secret set SERVER_HOST --body "your-server.example.com" --repo "$REPO"
gh secret set SERVER_USER --body "ubuntu" --repo "$REPO"
gh secret set SERVER_PORT --body "22" --repo "$REPO"

# Generate a deploy key
ssh-keygen -t ed25519 -C "github-actions-deploy" -f ~/.ssh/hermes_deploy -N ""
# Register the public key on your server
ssh-copy-id -i ~/.ssh/hermes_deploy.pub USER@YOUR_SERVER

# Add the private key to GitHub Secrets
gh secret set SERVER_SSH_KEY < ~/.ssh/hermes_deploy --repo "$REPO"
```

## Step 2: Initialize the Server

SSH into your server and run:

```bash
# Install Docker if not already installed
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
sudo systemctl enable docker

# Create the config directory
sudo mkdir -p /opt/YOUR_AGENT_NAME-config
sudo chown $USER:$USER /opt/YOUR_AGENT_NAME-config

# Clone the config repo
gh repo clone YOUR_ORG/YOUR_AGENT_NAME-config /opt/YOUR_AGENT_NAME-config
# or: git clone https://github.com/YOUR_ORG/YOUR_AGENT_NAME-config.git /opt/YOUR_AGENT_NAME-config
```

## Step 3: Place the .env File on the Server

The `.env` file was generated locally by `setup.sh`. Transfer it to the server:

```bash
# From your local machine:
scp ~/YOUR_AGENT_NAME-config/.env USER@YOUR_SERVER:/opt/YOUR_AGENT_NAME-config/.env
chmod 600 /opt/YOUR_AGENT_NAME-config/.env
```

The `.env` file is gitignored and must exist only on the server.

## Step 4: Start the Agent

```bash
cd /opt/YOUR_AGENT_NAME-config
docker compose up -d

# Check logs
docker compose logs -f
```

## Step 5: Verify

```bash
docker compose ps             # should show container running
docker compose logs --tail=50 # check for errors
```

---

## Day-2 Operations

### Update config or skills

```bash
# On your local machine:
git add . && git commit -m "feat: update skill"
git push origin main
# → GitHub Actions deploys automatically
```

### View logs

```bash
ssh USER@YOUR_SERVER "docker compose -f /opt/YOUR_AGENT_NAME-config/docker-compose.yml logs -f"
```

### Emergency rollback

```bash
# Revert last commit and push to trigger redeploy
git revert HEAD && git push origin main
```

### Backup runtime data

```bash
# On server — backup state.db from named volume
docker run --rm \
  -v YOUR_AGENT_NAME_data:/opt/data \
  -v /opt/hermes-backups:/backup \
  debian:12 \
  bash -c "cp /opt/data/state.db /backup/state_$(date +%Y%m%d_%H%M%S).db"
```

### Manual image update (without config change)

```bash
ssh USER@YOUR_SERVER "cd /opt/YOUR_AGENT_NAME-config && docker compose pull && docker compose up -d"
```
