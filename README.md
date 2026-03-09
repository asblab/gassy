# gassy

> **WARNING: This script is wildly insecure.** It curls and pipes install scripts as root, prompts you to paste private keys into a terminal, and runs agents with `--dangerously-skip-permissions`. It is designed for **throwaway, isolated VMs only**. Do not run this on a machine you care about. Use throwaway SSH keys — not your personal ones.

Install script for [Gas Town](https://github.com/steveyegge/gastown) — a multi-agent orchestrator for Claude Code. Tuned for the **Claude Max $200 subscription** (not API billing).

## Quick start

```bash
curl -fsSL https://raw.githubusercontent.com/asblab/gassy/master/install-gastown.sh | bash
```

Or fully automated with environment variables:

```bash
export GASSY_AUTHORIZED_KEYS="ssh-ed25519 AAAA..."
cat > /tmp/gassy-key <<'EOF'
-----BEGIN OPENSSH PRIVATE KEY-----
...paste key here...
-----END OPENSSH PRIVATE KEY-----
EOF
export GASSY_SSH_PRIVATE_KEY="file:/tmp/gassy-key"
export GASSY_GH_TOKEN="ghp_..."
export GASSY_CLAUDE_TOKEN="sk-ant-oat01-..."
export GASSY_TS_AUTH_KEY="tskey-auth-..."
curl -fsSL https://raw.githubusercontent.com/asblab/gassy/master/install-gastown.sh | bash
```

Or clone and run:

```bash
git clone https://github.com/asblab/gassy.git
bash gassy/install-gastown.sh
```

## What it installs

| Tool | Source |
|------|--------|
| Go (latest) | go.dev API auto-detect |
| Claude Code | claude.ai |
| gh CLI | GitHub apt repo |
| Dolt | dolthub/dolt |
| Beads (bd) | Built from source (steveyegge/beads) |
| Gas Town (gt) | Built from source with patch (steveyegge/gastown) |
| Tailscale | tailscale.com |

## What it configures

- Gas Town workspace at `~/gt`
- Economy cost tier (Opus for workers, Sonnet/Haiku for patrols)
- Agent aliases: `claude-sonnet`, `claude-haiku`
- Tailscale for remote access
- Git/Dolt identity from GitHub profile

## Requirements

- Debian/Ubuntu (uses apt)
- sudo access

## Environment variables

Set any of these before running to skip interactive prompts and automate auth:

| Variable | Value |
|----------|-------|
| `GASSY_AUTHORIZED_KEYS` | Public key(s) to add to `authorized_keys` (one per line, or `file:/path`) |
| `GASSY_SSH_PRIVATE_KEY` | ed25519 private key contents, or `file:/path/to/key` |
| `GASSY_GH_TOKEN` | GitHub personal access token (`ghp_...`) with `repo` scope |
| `GASSY_CLAUDE_TOKEN` | Claude Code OAuth token from `claude setup-token` (Max $200 subscription, not API) |
| `GASSY_TS_AUTH_KEY` | Tailscale pre-auth key (`tskey-auth-...`) |

## During install

Without env vars, the script prompts for three things upfront then runs unattended:

1. **SSH authorized_keys** — shows existing keys, option to add another
2. **SSH private key** (`id_ed25519`) — paste to configure GitHub SSH access
3. **Tailscale auth key** — pre-auth key from https://login.tailscale.com/admin/settings/keys

All three are optional — skip by pressing Enter (or Ctrl-D for the private key).

## After install

```bash
source ~/.bashrc
```

The script tells you which auth steps are still needed. If all env vars were set, you can go straight to:

```bash
cd ~/gt && gt rig add <name> <git-url>
gt mayor attach
```

