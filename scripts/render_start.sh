#!/bin/bash
set -e

CONFIG_DIR="${OPENCLAW_STATE_DIR:-/data/.openclaw}"
CONFIG_FILE="$CONFIG_DIR/openclaw.json"

# Use ephemeral storage for workspace and sessions to avoid filling /data
# The main overlay filesystem has 290GB vs /data's 1GB
WORKSPACE_DIR="${OPENCLAW_WORKSPACE_DIR:-/tmp/openclaw-workspace}"
SESSIONS_DIR="${OPENCLAW_SESSIONS_DIR:-/tmp/openclaw-sessions}"

# Create config directory
mkdir -p "$CONFIG_DIR"

# Create minimal config if it doesn't exist
if [ ! -f "$CONFIG_FILE" ]; then
  echo "Creating initial config..."
  cat > "$CONFIG_FILE" << EOF
{
  "gateway": {
    "controlUi": {
      "dangerouslyDisableDeviceAuth": true
    }
  },
  "auth": {
    "profiles": {
      "anthropic:default": {
        "provider": "anthropic",
        "mode": "token"
      },
      "openai:default": {
        "provider": "openai",
        "mode": "token"
      }
    }
  },
  "agents": {
    "defaults": {
      "model": {
        "primary": "anthropic/claude-sonnet-4-5",
        "fallbacks": ["openai/gpt-4.1"]
      },
      "workspace": "$WORKSPACE_DIR"
    }
  }
}
EOF
  echo "Config created at $CONFIG_FILE"
fi

# Create workspace and sessions directories (on ephemeral storage)
mkdir -p "$WORKSPACE_DIR"
mkdir -p "$SESSIONS_DIR"

# Symlink sessions to ephemeral storage if not already linked
if [ ! -L "$CONFIG_DIR/agents" ] && [ ! -d "$CONFIG_DIR/agents" ]; then
  mkdir -p "$SESSIONS_DIR/agents"
  ln -sf "$SESSIONS_DIR/agents" "$CONFIG_DIR/agents"
elif [ -d "$CONFIG_DIR/agents" ] && [ ! -L "$CONFIG_DIR/agents" ]; then
  # Move existing sessions to ephemeral storage
  echo "Moving sessions to ephemeral storage..."
  if [ -d "$CONFIG_DIR/agents" ]; then
    mv "$CONFIG_DIR/agents" "$SESSIONS_DIR/agents" 2>/dev/null || true
    ln -sf "$SESSIONS_DIR/agents" "$CONFIG_DIR/agents"
  fi
fi

# Clean up old /data contents that should now be on ephemeral storage
echo "Cleaning up old /data contents..."
rm -rf /data/workspace 2>/dev/null || true
rm -rf /data/.openclaw/agents 2>/dev/null || true
rm -rf /data/.openclaw/browser 2>/dev/null || true
rm -rf /data/.openclaw/memory 2>/dev/null || true

# Clean disk space before starting (Render has limited disk: 1GB)
echo "Checking disk space..."
df -h /data || true

# Check if disk is critically full (>95%) and use aggressive cleanup
DISK_USAGE=$(df /data 2>/dev/null | tail -1 | awk '{print $5}' | sed 's/%//' || echo "0")
CLEANUP_FLAGS=""
if [ "$DISK_USAGE" -gt 95 ]; then
  echo "WARNING: Disk critically full (${DISK_USAGE}%), using aggressive cleanup..."
  CLEANUP_FLAGS="--aggressive"
fi

echo "Running disk cleanup..."
bash scripts/cleanup-disk-space.sh $CLEANUP_FLAGS <<< "n" || {
  echo "Warning: Disk cleanup failed, continuing anyway..."
}

echo "Disk space after cleanup:"
df -h /data || true

# Show what's using space if still above 90%
DISK_USAGE_AFTER=$(df /data 2>/dev/null | tail -1 | awk '{print $5}' | sed 's/%//' || echo "0")
if [ "$DISK_USAGE_AFTER" -gt 90 ]; then
  echo ""
  echo "WARNING: Disk still above 90% after cleanup. Top space users:"
  du -sh /data/* 2>/dev/null | sort -h | tail -5 || true
fi

# Start the gateway
exec node --max-old-space-size=768 dist/index.js gateway --port "${PORT:-8080}" --bind lan --allow-unconfigured
