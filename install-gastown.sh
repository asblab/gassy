#!/usr/bin/env bash
#
# install-gastown.sh — Install Gas Town + all prerequisites, tuned for Claude Max $200
#
# Usage: bash install-gastown.sh
#
# Installs: Claude Code, Go (latest), gh CLI, Dolt, Beads (bd), Gas Town (gt), Tailscale
# Configures: economy cost tier, Claude agent aliases
# Requires: sudo access (Debian/Ubuntu)
#
set -euo pipefail

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${CYAN}==>${NC} ${BOLD}$*${NC}"; }
ok()    { echo -e "${GREEN} ✓${NC} $*"; }
warn()  { echo -e "${YELLOW} ⚠${NC} $*"; }
fail()  { echo -e "${RED} ✖${NC} $*"; exit 1; }

HQ_DIR="$HOME/gt"
SRC_DIR="$HOME/src"
PATH_LINE='export PATH="$PATH:/usr/local/bin:/usr/local/go/bin:$HOME/.local/bin:$HOME/go/bin"'

# ─── Step 1: OS packages ────────────────────────────────────────────────────
info "Installing OS packages"

PACKAGES=(build-essential git curl tmux libicu-dev libzstd-dev sqlite3)
MISSING=()
for pkg in "${PACKAGES[@]}"; do
    if ! dpkg -s "$pkg" &>/dev/null; then
        MISSING+=("$pkg")
    fi
done

if [ ${#MISSING[@]} -gt 0 ]; then
    info "Installing: ${MISSING[*]}"
    sudo apt-get update -qq
    sudo apt-get install -y -qq "${MISSING[@]}"
fi

command -v git  >/dev/null 2>&1 || fail "git not available"
command -v curl >/dev/null 2>&1 || fail "curl not available"
command -v tmux >/dev/null 2>&1 || fail "tmux not available"
ok "git $(git --version | awk '{print $3}')"
ok "curl installed"
ok "tmux $(tmux -V | awk '{print $2}')"

# ─── Step 1b: SSH keys & credentials ──────────────────────────────────────
# Environment variables skip interactive prompts:
#   GASSY_AUTHORIZED_KEYS — public key(s) to add to authorized_keys (one per line, or file:/path)
#   GASSY_SSH_PRIVATE_KEY — ed25519 private key contents (or file:/path)
#   GASSY_GH_TOKEN        — GitHub personal access token (ghp_...)
#   GASSY_CLAUDE_TOKEN    — Claude Code OAuth token (from `claude setup-token`)
#   GASSY_TS_AUTH_KEY     — Tailscale pre-auth key (tskey-auth-...)
info "SSH key setup"

SSH_DIR="$HOME/.ssh"
mkdir -p "$SSH_DIR" && chmod 700 "$SSH_DIR"

# Authorized keys
if [ -n "${GASSY_AUTHORIZED_KEYS:-}" ]; then
    if [[ "$GASSY_AUTHORIZED_KEYS" == file:* ]]; then
        cat "${GASSY_AUTHORIZED_KEYS#file:}" >> "$SSH_DIR/authorized_keys"
    else
        printf '%s\n' "$GASSY_AUTHORIZED_KEYS" >> "$SSH_DIR/authorized_keys"
    fi
    chmod 644 "$SSH_DIR/authorized_keys"
    ok "authorized_keys set from GASSY_AUTHORIZED_KEYS"
elif [ -f "$SSH_DIR/authorized_keys" ]; then
    echo ""
    echo -e "  ${CYAN}Existing authorized_keys:${NC}"
    while IFS= read -r line; do
        [ -n "$line" ] && echo -e "    $line"
    done < "$SSH_DIR/authorized_keys"
    echo ""
    read -rp "  Add another key? [y/N] " ADD_AUTH < /dev/tty
    if [[ "$ADD_AUTH" =~ ^[Yy] ]]; then
        echo "  Paste the public key to add, then press Enter:"
        read -r NEW_AUTH < /dev/tty
        if [ -n "$NEW_AUTH" ]; then
            echo "$NEW_AUTH" >> "$SSH_DIR/authorized_keys"
            ok "Key added to authorized_keys"
        fi
    else
        ok "Keeping existing authorized_keys"
    fi
else
    echo ""
    echo -e "  ${YELLOW}No authorized_keys found${NC}"
    echo "  Paste a public key to authorize (or leave blank to skip):"
    read -r NEW_AUTH < /dev/tty
    if [ -n "$NEW_AUTH" ]; then
        echo "$NEW_AUTH" > "$SSH_DIR/authorized_keys"
        chmod 644 "$SSH_DIR/authorized_keys"
        ok "authorized_keys created"
    else
        warn "Skipped — no authorized_keys configured"
    fi
fi

# Private key (supports file: prefix, e.g. GASSY_SSH_PRIVATE_KEY=file:/path/to/key)
if [ -n "${GASSY_SSH_PRIVATE_KEY:-}" ]; then
    if [[ "$GASSY_SSH_PRIVATE_KEY" == file:* ]]; then
        cp "${GASSY_SSH_PRIVATE_KEY#file:}" "$SSH_DIR/id_ed25519"
    else
        printf '%s\n' "$GASSY_SSH_PRIVATE_KEY" > "$SSH_DIR/id_ed25519"
    fi
    chmod 600 "$SSH_DIR/id_ed25519"
    ok "Private key set from GASSY_SSH_PRIVATE_KEY"
elif [ -f "$SSH_DIR/id_ed25519" ]; then
    ok "Private key already exists at $SSH_DIR/id_ed25519"
    read -rp "  Replace it? [y/N] " REPLACE_PRIV < /dev/tty
    if [[ "$REPLACE_PRIV" =~ ^[Yy] ]]; then
        echo "  Paste your private key (id_ed25519), then press Ctrl-D on a new line:"
        cat < /dev/tty > "$SSH_DIR/id_ed25519"
        chmod 600 "$SSH_DIR/id_ed25519"
        ok "Private key replaced"
    else
        ok "Keeping existing private key"
    fi
else
    echo ""
    echo -e "  ${YELLOW}No private key found at $SSH_DIR/id_ed25519${NC}"
    echo "  Paste your private key (id_ed25519), then press Ctrl-D on a new line (or Ctrl-D immediately to skip):"
    if cat < /dev/tty > /tmp/ssh_priv_tmp && [ -s /tmp/ssh_priv_tmp ]; then
        mv /tmp/ssh_priv_tmp "$SSH_DIR/id_ed25519"
        chmod 600 "$SSH_DIR/id_ed25519"
        ok "Private key saved"
    else
        rm -f /tmp/ssh_priv_tmp
        warn "Skipped — no private key configured"
    fi
fi

# Derive public key from private if missing
if [ -f "$SSH_DIR/id_ed25519" ] && [ ! -f "$SSH_DIR/id_ed25519.pub" ]; then
    ssh-keygen -y -f "$SSH_DIR/id_ed25519" > "$SSH_DIR/id_ed25519.pub" 2>/dev/null
    ok "Derived public key from private key"
fi

# Ensure known_hosts has GitHub
if ! grep -q 'github.com' "$SSH_DIR/known_hosts" 2>/dev/null; then
    ssh-keyscan -t ed25519 github.com >> "$SSH_DIR/known_hosts" 2>/dev/null
    ok "Added github.com to known_hosts"
fi

HAS_SSH_KEY=false
if [ -f "$SSH_DIR/id_ed25519" ] && [ -f "$SSH_DIR/id_ed25519.pub" ]; then
    HAS_SSH_KEY=true
    ok "SSH keypair ready"
fi

# Tailscale auth key
if [ -n "${GASSY_TS_AUTH_KEY:-}" ]; then
    TS_AUTH_KEY="$GASSY_TS_AUTH_KEY"
    ok "Tailscale auth key set from GASSY_TS_AUTH_KEY"
else
    echo ""
    echo -e "  ${CYAN}Tailscale auth key${NC} (generate at https://login.tailscale.com/admin/settings/keys)"
    echo "  Paste your auth key (tskey-auth-...), or leave blank to skip:"
    read -r TS_AUTH_KEY < /dev/tty
    if [ -n "$TS_AUTH_KEY" ]; then
        ok "Tailscale auth key saved for later"
    else
        warn "Skipped — will need manual 'sudo tailscale up' after install"
    fi
fi

# ─── Step 2: Go (latest stable) ─────────────────────────────────────────────
info "Installing Go"

if command -v go >/dev/null 2>&1; then
    ok "Go already installed ($(go version))"
else
    GO_JSON="$(curl -fsSL 'https://go.dev/dl/?mode=json')"
    GO_VERSION="$(echo "$GO_JSON" | grep -m1 '"version"' | sed 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')"
    ARCH="$(dpkg --print-architecture)"
    info "Downloading ${GO_VERSION} for ${ARCH}"
    curl -fsSL "https://go.dev/dl/${GO_VERSION}.linux-${ARCH}.tar.gz" -o /tmp/go.tar.gz
    sudo rm -rf /usr/local/go
    sudo tar -C /usr/local -xzf /tmp/go.tar.gz
    rm /tmp/go.tar.gz
    ok "Go ${GO_VERSION} installed"
fi

# Update PATH for this session and persist in .bashrc
export PATH="$PATH:/usr/local/bin:/usr/local/go/bin:$HOME/.local/bin:$HOME/go/bin"
if grep -qF '/usr/local/go/bin' "$HOME/.bashrc" 2>/dev/null; then
    sed -i '/\/usr\/local\/go\/bin/d' "$HOME/.bashrc"
fi
sed -i '/.local\/bin.*go\/bin/d' "$HOME/.bashrc"
echo "$PATH_LINE" >> "$HOME/.bashrc"
ok "PATH updated in ~/.bashrc"

go version >/dev/null 2>&1 || fail "Go not in PATH"
mkdir -p "$HOME/go/bin"

# ─── Step 3: Claude Code ────────────────────────────────────────────────────
info "Installing Claude Code"

if command -v claude >/dev/null 2>&1; then
    ok "Claude Code $(claude --version 2>&1 | head -1) already installed"
else
    curl -fsSL https://claude.ai/install.sh | bash
    export PATH="$HOME/.local/bin:$PATH"
    command -v claude >/dev/null 2>&1 || fail "Claude Code installation failed"
    ok "Claude Code $(claude --version 2>&1 | head -1) installed"
fi

NEED_CLAUDE_AUTH=false
if [ -n "${GASSY_CLAUDE_TOKEN:-}" ]; then
    export CLAUDE_CODE_OAUTH_TOKEN="$GASSY_CLAUDE_TOKEN"
    if ! grep -qF 'CLAUDE_CODE_OAUTH_TOKEN' "$HOME/.bashrc" 2>/dev/null; then
        echo "export CLAUDE_CODE_OAUTH_TOKEN=\"$GASSY_CLAUDE_TOKEN\"" >> "$HOME/.bashrc"
    fi
    # Skip onboarding so spawned agents don't get stuck at theme picker
    CLAUDE_JSON="$HOME/.claude.json"
    if [ -f "$CLAUDE_JSON" ]; then
        if command -v python3 >/dev/null 2>&1; then
            python3 -c "
import json, sys
with open('$CLAUDE_JSON') as f: d = json.load(f)
d['hasCompletedOnboarding'] = True
with open('$CLAUDE_JSON', 'w') as f: json.dump(d, f, indent=2)
" 2>/dev/null && ok "Onboarding marked complete"
        fi
    else
        echo '{"hasCompletedOnboarding":true}' > "$CLAUDE_JSON"
        ok "Created ~/.claude.json with onboarding complete"
    fi
    ok "Claude token set from GASSY_CLAUDE_TOKEN"
fi
if ! claude auth status >/dev/null 2>&1; then
    NEED_CLAUDE_AUTH=true
fi

# ─── Step 4: gh CLI ─────────────────────────────────────────────────────────
info "Installing gh CLI"

if command -v gh >/dev/null 2>&1; then
    ok "gh $(gh --version | head -1 | awk '{print $3}') already installed"
else
    sudo mkdir -p -m 755 /etc/apt/keyrings
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
    sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
    sudo apt-get update -qq
    sudo apt-get install -y -qq gh
    ok "gh $(gh --version | head -1 | awk '{print $3}') installed"
fi

NEED_GH_AUTH=false
if [ -n "${GASSY_GH_TOKEN:-}" ]; then
    export GH_TOKEN="$GASSY_GH_TOKEN"
    if ! grep -qF 'GH_TOKEN' "$HOME/.bashrc" 2>/dev/null; then
        echo "export GH_TOKEN=\"$GASSY_GH_TOKEN\"" >> "$HOME/.bashrc"
    fi
    gh auth setup-git
    ok "GitHub token set from GASSY_GH_TOKEN"
fi
if gh auth status &>/dev/null; then
    ok "Already authenticated with GitHub"
    # Configure git identity from GitHub profile
    info "Configuring git identity from GitHub"
    GIT_NAME="$(gh api user --jq '.name')"
    if [ -z "$GIT_NAME" ] || [ "$GIT_NAME" = "null" ]; then
        GIT_NAME="$(gh api user --jq '.login')"
    fi
    GIT_EMAIL="$(gh api user --jq '.email')"
    if [ -z "$GIT_EMAIL" ] || [ "$GIT_EMAIL" = "null" ]; then
        GIT_EMAIL="$(gh api user --jq '.login')@localhost"
    fi
    git config --global user.name "$GIT_NAME"
    git config --global user.email "$GIT_EMAIL"
    gh auth setup-git
    git config --global init.defaultBranch main
    ok "Git identity: $GIT_NAME <$GIT_EMAIL>"
else
    NEED_GH_AUTH=true
    GIT_NAME="$(whoami)"
    GIT_EMAIL="$(whoami)@localhost"
    git config --global user.name "$GIT_NAME"
    git config --global user.email "$GIT_EMAIL"
    git config --global init.defaultBranch main
fi

# ─── Step 5: Dolt ───────────────────────────────────────────────────────────
info "Installing Dolt"

if command -v dolt >/dev/null 2>&1; then
    ok "Dolt $(dolt version | awk '{print $3}') already installed"
else
    sudo bash -c 'curl -fsSL https://github.com/dolthub/dolt/releases/latest/download/install.sh | bash'
    command -v dolt >/dev/null 2>&1 || fail "Dolt installation failed"
    ok "Dolt $(dolt version | awk '{print $3}') installed"
fi

info "Configuring Dolt identity"
dolt config --global --add user.name "$GIT_NAME" 2>/dev/null || true
dolt config --global --add user.email "$GIT_EMAIL" 2>/dev/null || true
ok "Dolt identity: $GIT_NAME <$GIT_EMAIL>"

# ─── Step 6: Beads (from source) ────────────────────────────────────────────
info "Installing Beads (bd)"

BEADS_SRC="$SRC_DIR/beads"
if command -v bd >/dev/null 2>&1; then
    ok "Beads already installed ($(bd version | awk '{print $3}'))"
else
    mkdir -p "$SRC_DIR"
    if [ -d "$BEADS_SRC" ]; then
        warn "$BEADS_SRC already exists, rebuilding"
    else
        git clone https://github.com/steveyegge/beads.git "$BEADS_SRC"
    fi
    (cd "$BEADS_SRC" && go build -o "$HOME/go/bin/bd" ./cmd/bd)
    command -v bd >/dev/null 2>&1 || fail "Beads build failed"
    ok "Beads $(bd version | awk '{print $3}') installed"
fi

# ─── Step 7: Gas Town (from source, with patch) ─────────────────────────────
info "Installing Gas Town (gt)"

GASTOWN_SRC="$SRC_DIR/gastown"
if command -v gt >/dev/null 2>&1; then
    ok "Gas Town already installed ($(gt version 2>/dev/null | grep 'gt version' | awk '{print $3}'))"
else
    mkdir -p "$SRC_DIR"
    if [ -d "$GASTOWN_SRC" ]; then
        warn "$GASTOWN_SRC already exists, rebuilding"
    else
        git clone https://github.com/steveyegge/gastown.git "$GASTOWN_SRC"
    fi
(cd "$GASTOWN_SRC" && go build -o "$HOME/go/bin/gt" ./cmd/gt)
    command -v gt >/dev/null 2>&1 || fail "Gas Town build failed"
    ok "Gas Town $(gt version 2>/dev/null | grep 'gt version' | awk '{print $3}') installed"
fi

# ─── Step 8: Create workspace ───────────────────────────────────────────────
info "Setting up Gas Town workspace at ${HQ_DIR}"

if [ -d "$HQ_DIR/mayor" ]; then
    warn "${HQ_DIR} already exists, skipping gt install"
else
    gt install "$HQ_DIR" --shell
    ok "Workspace created"
fi

info "Enabling Gas Town"
(cd "$HQ_DIR" && gt enable 2>&1) || warn "gt enable had issues (may be OK)"

if [ -d "$HQ_DIR/.git" ]; then
    ok "Git already initialized in workspace"
else
    info "Initializing git in workspace"
    (cd "$HQ_DIR" && gt git-init 2>&1) || warn "gt git-init had issues"
    ok "Git initialized"
fi

info "Priming identity anchor"
(cd "$HQ_DIR" && gt prime 2>&1) || warn "gt prime had issues"

info "Starting services"
(cd "$HQ_DIR" && gt up 2>&1) || warn "gt up had issues"
sleep 2

# ─── Step 9: Configure agents ───────────────────────────────────────────────
info "Configuring for Claude Max \$200 subscription"

(cd "$HQ_DIR" && gt config default-agent claude)
ok "Default agent: claude"

(cd "$HQ_DIR" && gt config agent set claude-sonnet "claude --model sonnet --dangerously-skip-permissions")
ok "Agent alias: claude-sonnet"

(cd "$HQ_DIR" && gt config agent set claude-haiku "claude --model haiku --dangerously-skip-permissions")
ok "Agent alias: claude-haiku"

(cd "$HQ_DIR" && gt config cost-tier economy)
ok "Cost tier: economy (Opus for workers, Sonnet/Haiku for patrols)"

# ─── Step 10: Tailscale ────────────────────────────────────────────────────
info "Installing Tailscale"

if command -v tailscale >/dev/null 2>&1; then
    ok "Tailscale already installed ($(tailscale version | head -1))"
else
    curl -fsSL https://tailscale.com/install.sh | sudo bash
    command -v tailscale >/dev/null 2>&1 || fail "Tailscale installation failed"
    ok "Tailscale $(tailscale version | head -1) installed"
fi

NEED_TS_AUTH=false
if tailscale status &>/dev/null; then
    ok "Tailscale already connected"
elif [ -n "${TS_AUTH_KEY:-}" ]; then
    info "Connecting Tailscale with auth key"
    if sudo tailscale up --auth-key "$TS_AUTH_KEY"; then
        ok "Tailscale connected"
    else
        warn "Tailscale auth failed — you'll need to run 'sudo tailscale up' manually"
        NEED_TS_AUTH=true
    fi
else
    NEED_TS_AUTH=true
fi

# ─── Step 11: Doctor fix ────────────────────────────────────────────────────
info "Running final health check"

(cd "$HQ_DIR" && gt doctor --fix 2>&1) || true

# ─── Summary ────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}═══════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}  Gas Town installation complete!${NC}"
echo -e "${BOLD}═══════════════════════════════════════${NC}"
echo ""
echo -e "  Claude:   $(claude --version 2>&1 | head -1)"
echo -e "  Go:       $(go version | awk '{print $3}')"
echo -e "  gh:       $(gh --version | head -1 | awk '{print $3}')"
echo -e "  Dolt:     $(dolt version | awk '{print $3}')"
echo -e "  Beads:    $(bd version | awk '{print $3}')"
echo -e "  Gas Town: $(gt version 2>/dev/null | grep 'gt version' | awk '{print $3}')"
echo ""
echo -e "  Workspace: ${HQ_DIR}"
echo -e "  Cost tier: economy"
echo -e "  Default:   claude (Opus)"
echo -e "  Mayor:     claude-sonnet"
echo -e "  Deacon:    claude-haiku"
echo ""
STEP=0
echo -e "  ${CYAN}First:${NC}"
STEP=$((STEP + 1))
echo -e "    ${STEP}. source ~/.bashrc"
echo ""

NEED_AUTH=false
if [ "$NEED_GH_AUTH" = true ] || [ "$NEED_CLAUDE_AUTH" = true ] || [ "$NEED_TS_AUTH" = true ]; then
    NEED_AUTH=true
    echo -e "  ${YELLOW}${BOLD}Authentication required:${NC}"
fi
if [ "$NEED_GH_AUTH" = true ]; then
    STEP=$((STEP + 1))
    if [ "$HAS_SSH_KEY" = true ]; then
        echo -e "    ${STEP}. gh auth login --hostname github.com --git-protocol ssh --web"
    else
        echo -e "    ${STEP}. gh auth login --hostname github.com --git-protocol ssh --skip-ssh-key --web"
    fi
fi
if [ "$NEED_CLAUDE_AUTH" = true ]; then
    STEP=$((STEP + 1))
    echo -e "    ${STEP}. claude   ${YELLOW}(auth only — exit when it asks to trust your home directory)${NC}"
fi
if [ "$NEED_TS_AUTH" = true ]; then
    STEP=$((STEP + 1))
    echo -e "    ${STEP}. sudo tailscale up"
fi
if [ "$NEED_AUTH" = true ]; then
    echo ""
fi

echo -e "  ${CYAN}Next steps:${NC}"
STEP=$((STEP + 1))
echo -e "    ${STEP}. cd ~/gt && gt rig add <name> <git-url>"
STEP=$((STEP + 1))
echo -e "    ${STEP}. gt mayor attach"
echo ""
