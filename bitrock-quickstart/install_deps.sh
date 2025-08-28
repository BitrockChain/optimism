#!/usr/bin/env bash
set -euo pipefail

# Bitrock L2 — Dependencies-only installer (IDEMPOTENT)
# Installs/validates: git, make, jq, direnv, curl, build-essential, unzip,
# Docker + Compose plugin, Node.js 20 + pnpm, Go>=1.21 (arch-aware),
# Foundry (forge/cast/anvil), and just (>=1.34).

# ─────────────────────────────────────────────────────────────────────────────
require_root_or_sudo() {
  if [[ $EUID -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
      echo "ℹ️  Running with sudo…"
      exec sudo -E bash "$0" "$@"
    else
      echo "❌ Please run as root or install sudo."; exit 1
    fi
  fi
}
require_root_or_sudo "$@"

say() { printf "\n%s\n" "$*"; }
has_cmd() { command -v "$1" >/dev/null 2>&1; }
version_ge() { awk -v A="${1#v}" -v B="${2#v}" '
  function splitver(v,a, n,i){n=split(v,a,".");for(i=n+1;i<=4;i++)a[i]=0}
  BEGIN{splitver(A,a);splitver(B,b);for(i=1;i<=4;i++){if(a[i]+0>b[i]+0)exit 0;if(a[i]+0<b[i]+0)exit 1}exit 0}
'; }

export DEBIAN_FRONTEND=noninteractive

# ── Arch detect (Go + just) ──────────────────────────────────────────────────
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64) GO_ARCH="linux-amd64"; JUST_ASSET="x86_64-unknown-linux-musl";;
  aarch64|arm64) GO_ARCH="linux-arm64"; JUST_ASSET="aarch64-unknown-linux-musl";;
  *) echo "❌ Unsupported architecture: $ARCH"; exit 1;;
esac

GO_VER_WANT="1.21.6"
GO_TARBALL="go${GO_VER_WANT}.${GO_ARCH}.tar.gz"
GO_URL="https://go.dev/dl/${GO_TARBALL}"
JUST_VER_WANT="1.35.0"

# ── apt helper (with retry) ──────────────────────────────────────────────────
APT_UPDATED=0
apt_update_once() {
  if [[ $APT_UPDATED -eq 0 ]]; then
    say "🔧 Updating apt…"
    for i in {1..3}; do
      if apt-get update -yq; then APT_UPDATED=1; break; fi
      sleep 2
    done
    if [[ $APT_UPDATED -eq 0 ]]; then echo "❌ apt update failed"; exit 1; fi
  fi
}
apt_install() {
  apt_update_once
  apt-get install -yq "$@"
}

curl_dl() { curl -fsSL --retry 3 --retry-delay 2 "$@"; }

# ── Base packages ────────────────────────────────────────────────────────────
say "🧰 Installing base packages (git, make, jq, direnv, curl, build-essential, unzip, certs)…"
apt_install git make jq direnv curl build-essential unzip ca-certificates gnupg lsb-release

# ── Docker + Compose ─────────────────────────────────────────────────────────
if has_cmd docker; then
  say "🐳 Docker already installed → $(docker --version)"
else
  say "🐳 Installing Docker Engine…"
  curl_dl https://get.docker.com | bash
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable docker || true
    systemctl start docker || true
  fi
fi
if docker compose version >/dev/null 2>&1; then
  say "🧩 Docker Compose plugin already installed → $(docker compose version | head -n1)"
else
  say "🧩 Installing Docker Compose plugin…"
  apt_install docker-compose-plugin
fi
# add invoking user to docker group (so they can use docker without sudo next login)
if [[ -n "${SUDO_USER:-}" ]]; then usermod -aG docker "$SUDO_USER" || true; fi

# ── Node.js 20 + pnpm (via corepack) ─────────────────────────────────────────
NODE_OK=0
if has_cmd node; then
  NODE_VER="$(node --version 2>/dev/null || true)"
  version_ge "$NODE_VER" "v20.0.0" && NODE_OK=1
fi
if [[ $NODE_OK -eq 1 ]]; then
  say "🟢 Node already installed → $NODE_VER"
else
  say "🟢 Installing Node.js 20 + npm…"
  curl_dl https://deb.nodesource.com/setup_20.x | bash -
  apt_install nodejs
fi
# Prefer corepack to install pnpm
if has_cmd pnpm; then
  say "🟣 pnpm already installed → $(pnpm --version)"
else
  if command -v corepack >/dev/null 2>&1; then
    corepack enable || true
    corepack prepare pnpm@latest --activate || npm install -g pnpm
  else
    npm install -g pnpm
  fi
  say "🟣 pnpm installed → $(pnpm --version)"
fi

# ── Go (>=1.21) ──────────────────────────────────────────────────────────────
GO_OK=0
if has_cmd go; then
  GO_CUR="$(go version 2>/dev/null | awk '{print $3}')"; GO_CUR="${GO_CUR#go}"
  version_ge "$GO_CUR" "1.21.0" && GO_OK=1
fi
if [[ $GO_OK -eq 1 ]]; then
  say "🐹 Go already installed → go${GO_CUR}"
else
  say "🐹 Installing Go ${GO_VER_WANT} (${GO_ARCH})…"
  rm -rf /usr/local/go
  curl_dl "${GO_URL}" -o "/tmp/${GO_TARBALL}"
  tar -C /usr/local -xzf "/tmp/${GO_TARBALL}"
fi

# Ensure PATH for Go system-wide + current shell
install -m 644 /dev/stdin /etc/profile.d/go.sh <<'EOF'
export PATH=/usr/local/go/bin:$PATH
EOF
export PATH=/usr/local/go/bin:$PATH
hash -r

# Also add symlinks so it's always in PATH even if /etc/profile.d isn't sourced
ln -sf /usr/local/go/bin/go /usr/local/bin/go
ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt



# ── Foundry (forge/cast/anvil) ───────────────────────────────────────────────
if has_cmd forge; then
  say "🧪 Foundry already installed → $(forge --version | head -n1)"
else
  say "🧪 Installing Foundry (forge/cast/anvil)…"
  curl_dl https://foundry.paradigm.xyz | bash
  /root/.foundry/bin/foundryup || true
fi
# Ensure PATH for Foundry system-wide + immediate
install -m 644 /dev/stdin /etc/profile.d/foundry.sh <<'EOF'
if [ -d /root/.foundry/bin ]; then
  export PATH=$PATH:/root/.foundry/bin
fi
EOF
export PATH=$PATH:/root/.foundry/bin
# Symlink tools for immediate availability
for TOOL in forge cast anvil; do
  if [ -x "/root/.foundry/bin/$TOOL" ] && [ ! -e "/usr/local/bin/$TOOL" ]; then
    ln -sf "/root/.foundry/bin/$TOOL" "/usr/local/bin/$TOOL"
  fi
done

# ── just (>=1.34.0) ──────────────────────────────────────────────────────────
JUST_OK=0
if has_cmd just; then
  JUST_CUR="$(just --version 2>/dev/null | awk '{print $2}')"
  version_ge "$JUST_CUR" "1.34.0" && JUST_OK=1
fi
if [[ $JUST_OK -eq 1 ]]; then
  say "🧾 just already installed → $(just --version)"
else
  say "🧾 Installing just ${JUST_VER_WANT}…"
  URL="https://github.com/casey/just/releases/download/${JUST_VER_WANT}/just-${JUST_VER_WANT}-${JUST_ASSET}.tar.gz"
  curl_dl "$URL" -o /tmp/just.tgz
  # the tar may contain either 'just' or a subdir; extract then move
  tmpdir="$(mktemp -d)"; tar -xzf /tmp/just.tgz -C "$tmpdir"
  if [ -f "$tmpdir/just" ]; then
    install -m 755 "$tmpdir/just" /usr/local/bin/just
  else
    install -m 755 "$(find "$tmpdir" -type f -name just -maxdepth 2 | head -n1)" /usr/local/bin/just
  fi
  rm -rf "$tmpdir" /tmp/just.tgz
fi

# ── Done ─────────────────────────────────────────────────────────────────────
say "✅ All dependencies installed (or already present)."

say "🔎 Versions:"
{ git --version || true; }                | sed 's/^/  /'
{ go version || true; }                   | sed 's/^/  /'
{ node --version || true; }               | sed 's/^/  /'
{ pnpm --version || true; }               | sed 's/^/  /'
{ forge --version || true; }              | sed 's/^/  /'
{ just --version || true; }               | sed 's/^/  /'
{ make --version | head -n1 || true; }    | sed 's/^/  /'
{ jq --version || true; }                 | sed 's/^/  /'
{ direnv --version || true; }             | sed 's/^/  /'
{ docker --version || true; }             | sed 's/^/  /'
{ docker compose version || true; }       | sed 's/^/  /'

echo
echo "ℹ️  Reconnect your SSH session or run:  source /etc/profile"