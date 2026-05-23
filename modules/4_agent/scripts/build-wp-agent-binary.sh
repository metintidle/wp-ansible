#!/usr/bin/env bash
# Build wp-agent for Amazon Linux 2023 (x86_64, x86-64-v2) into files/wp-agent-linux-x86_64.
#
# Preferred: compile on an AL2023 host (native glibc), then scp the binary back.
#   WP_BUILD_HOST=greenfarm ./scripts/build-wp-agent-binary.sh
#
# Fallback: cross-compile on macOS with zig + cargo-zigbuild (static musl).
#   ./scripts/build-wp-agent-binary.sh --local
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
RESMON="${RESMON_ROOT:-$ROOT/../resmon}"
OUT="$ROOT/modules/4_agent/files/wp-agent-linux-x86_64"
BUILD_HOST="${WP_BUILD_HOST:-greenfarm}"
MODE="${1:-remote}"

build_remote() {
  if [[ ! -d "$RESMON/apps/wp-agent" ]]; then
    echo "resmon not found at $RESMON — set RESMON_ROOT" >&2
    exit 1
  fi
  echo "Building on AL2023 host: $BUILD_HOST"
  rsync -az --exclude target --exclude .git \
    "$RESMON/apps/wp-agent/" "${BUILD_HOST}:/tmp/wp-agent-src/"
  ssh "$BUILD_HOST" 'bash -s' <<'REMOTE'
set -euo pipefail
source "$HOME/.cargo/env" 2>/dev/null || true
if ! command -v cargo >/dev/null 2>&1; then
  curl -sSf https://sh.rustup.rs | sh -s -- -y
  source "$HOME/.cargo/env"
fi
sudo dnf install -y openssl-devel perl-IPC-Cmd perl-FindBin gcc >/dev/null
cd /tmp/wp-agent-src
export RUSTFLAGS='-C target-cpu=x86-64-v2'
cargo build --release
file target/release/wp-agent
REMOTE
  scp "${BUILD_HOST}:/tmp/wp-agent-src/target/release/wp-agent" "$OUT"
}

build_local() {
  if [[ ! -d "$RESMON/apps/wp-agent" ]]; then
    echo "resmon not found at $RESMON — set RESMON_ROOT" >&2
    exit 1
  fi
  command -v cargo-zigbuild >/dev/null 2>&1 || cargo install cargo-zigbuild --locked
  command -v zig >/dev/null 2>&1 || { echo "Install zig: brew install zig" >&2; exit 1; }
  rustup target add x86_64-unknown-linux-musl >/dev/null 2>&1 || true
  cd "$RESMON/apps/wp-agent"
  RUSTFLAGS='-C target-cpu=x86-64-v2' cargo zigbuild --release --target x86_64-unknown-linux-musl
  install -m 0755 \
    "$RESMON/apps/wp-agent/target/x86_64-unknown-linux-musl/release/wp-agent" \
    "$OUT"
}

case "$MODE" in
  --local) build_local ;;
  --remote|remote) build_remote ;;
  *)
    echo "Usage: $0 [--remote|--local]" >&2
    exit 1
    ;;
esac

chmod 0755 "$OUT"
file "$OUT"
echo "Installed: $OUT"
