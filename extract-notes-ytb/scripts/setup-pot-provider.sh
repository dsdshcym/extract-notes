#!/usr/bin/env bash
# Install / update the bgutil PO Token provider for yt-dlp (script mode, no daemon).
#
# Why: YouTube binds a GVS PO Token (proof-of-origin) to media URLs. Without it,
# audio downloads 403. This provider mints the token on demand so the *default*
# player client works — the durable fix that doesn't depend on pinning a client.
#
# Script mode (option b in the bgutil README): no always-on HTTP server. yt-dlp
# spawns `deno` only when a token is needed. Requires deno (>=2.0) on PATH.
#
# Idempotent: re-run to update to the pinned version. Usage: setup-pot-provider.sh
#
# References:
#   https://github.com/Brainicism/bgutil-ytdlp-pot-provider
#   https://github.com/yt-dlp/yt-dlp/wiki/PO-Token-Guide

set -euo pipefail

# Pin to a known-good release; bump deliberately. Plugin and server must match.
BGUTIL_VERSION="1.3.1"
SERVER_HOME="$HOME/bgutil-ytdlp-pot-provider"
PLUGIN_DIR="$HOME/.config/yt-dlp/plugins/bgutil"

log() { echo "[setup-pot-provider] $*" >&2; }

command -v deno >/dev/null 2>&1 || {
  log "ERROR: deno not found on PATH. Install with: brew install deno"
  exit 1
}
command -v git >/dev/null 2>&1 || { log "ERROR: git required"; exit 1; }

# 1. Server / generation script (built with deno; spawned on demand by the plugin).
if [[ -d "$SERVER_HOME/.git" ]]; then
  log "updating server checkout at $SERVER_HOME"
  git -C "$SERVER_HOME" fetch --tags --quiet
  git -C "$SERVER_HOME" checkout --quiet "$BGUTIL_VERSION"
else
  log "cloning bgutil server -> $SERVER_HOME"
  rm -rf "$SERVER_HOME"
  git clone --quiet --single-branch --branch "$BGUTIL_VERSION" \
    https://github.com/Brainicism/bgutil-ytdlp-pot-provider.git "$SERVER_HOME"
fi

log "installing server deps with deno (allow-scripts for canvas)..."
( cd "$SERVER_HOME/server" && deno install --allow-scripts=npm:canvas --frozen >&2 )

# 2. Plugin into the yt-dlp user plugin dir.
#
# IMPORTANT layout note: yt-dlp's plugin finder takes each *child* of the
# `plugins/` folder as a search root and then appends `yt_dlp_plugins/...`.
# So the zip's `yt_dlp_plugins/` must sit one level *inside* a container dir,
# i.e. plugins/bgutil/yt_dlp_plugins/extractor/*.py  (NOT plugins/yt_dlp_plugins).
# Installing under ~/.config/yt-dlp/plugins (not the brew venv) survives
# `brew upgrade yt-dlp`.
log "installing plugin -> $PLUGIN_DIR"
TMP_ZIP="$(mktemp -t bgutil-plugin.XXXXXX.zip)"
ASSET_URL="https://github.com/Brainicism/bgutil-ytdlp-pot-provider/releases/download/${BGUTIL_VERSION}/bgutil-ytdlp-pot-provider.zip"
if command -v gh >/dev/null 2>&1; then
  gh release download "$BGUTIL_VERSION" \
    --repo Brainicism/bgutil-ytdlp-pot-provider \
    --pattern "bgutil-ytdlp-pot-provider.zip" -O "$TMP_ZIP" --clobber >&2
else
  curl -fsSL "$ASSET_URL" -o "$TMP_ZIP"
fi

rm -rf "$PLUGIN_DIR"
mkdir -p "$PLUGIN_DIR"
unzip -oq "$TMP_ZIP" -d "$PLUGIN_DIR"   # -> $PLUGIN_DIR/yt_dlp_plugins/...
rm -f "$TMP_ZIP"

# 3. Verify the provider is visible to yt-dlp.
log "verifying..."
if yt-dlp -v --simulate "https://youtu.be/dQw4w9WgXcQ" 2>&1 \
     | grep -qiE "PO Token Providers:.*bgutil"; then
  log "OK: bgutil PO token provider is active."
else
  log "WARNING: bgutil provider not detected in yt-dlp verbose output."
  log "Check: yt-dlp -v <url> 2>&1 | grep 'PO Token Providers'"
  exit 1
fi
