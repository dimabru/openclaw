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

# Create or update config file
# Note: port/bind are also set via env vars as backup, but setting in config
# ensures consistency across restarts and removes any stale settings
GATEWAY_PORT="${PORT:-8080}"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "Creating initial config..."
  cat > "$CONFIG_FILE" << EOF
{
  "gateway": {
    "port": $GATEWAY_PORT,
    "bind": "lan",
    "trustedProxies": ["10.0.0.0/8"]
  },
  "plugins": {
    "entries": {
      "whatsapp": { "enabled": true },
      "telegram": { "enabled": true },
      "discord": { "enabled": true },
      "slack": { "enabled": true },
      "signal": { "enabled": true }
    }
  },
  "models": {
    "mode": "merge",
    "providers": {
      "ollama": {
        "baseUrl": "https://desktop-0qhu65q.taila384a4.ts.net/v1",
        "apiKey": "ollama-local",
        "api": "openai-completions",
        "models": [
          {
            "id": "llama3.1",
            "name": "Llama 3.1",
            "reasoning": false,
            "input": ["text"],
            "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 },
            "contextWindow": 131072,
            "maxTokens": 4096
          }
        ]
      }
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
        "primary": "ollama/llama3.1",
        "fallbacks": ["openai/gpt-5.2"]
      },
      "workspace": "$WORKSPACE_DIR"
    }
  }
}
EOF
  echo "Config created at $CONFIG_FILE"
else
  echo "Updating existing config with Render gateway settings..."
  # Use node to update config (jq may not be available in all images)
  node -e "
    const fs = require('fs');
    const cfg = JSON.parse(fs.readFileSync('$CONFIG_FILE', 'utf8'));
    cfg.gateway = cfg.gateway || {};
    cfg.gateway.port = $GATEWAY_PORT;
    cfg.gateway.bind = 'lan';
    cfg.gateway.trustedProxies = ['10.0.0.0/8'];
    // Remove dangerouslyDisableDeviceAuth if it was previously set
    if (cfg.gateway.controlUi) {
      delete cfg.gateway.controlUi.dangerouslyDisableDeviceAuth;
    }
    // Enable channel plugins (bundled plugins are disabled by default)
    cfg.plugins = cfg.plugins || {};
    cfg.plugins.entries = cfg.plugins.entries || {};
    cfg.plugins.entries.whatsapp = { enabled: true };
    cfg.plugins.entries.telegram = { enabled: true };
    cfg.plugins.entries.discord = { enabled: true };
    cfg.plugins.entries.slack = { enabled: true };
    cfg.plugins.entries.signal = { enabled: true };
    // Ollama provider (Tailscale-connected local instance)
    cfg.models = cfg.models || {};
    cfg.models.mode = 'merge';
    cfg.models.providers = cfg.models.providers || {};
    cfg.models.providers.ollama = {
      baseUrl: 'https://desktop-0qhu65q.taila384a4.ts.net/v1',
      apiKey: 'ollama-local',
      api: 'openai-completions',
      models: [
        {
          id: 'llama3.1',
          name: 'Llama 3.1',
          reasoning: false,
          input: ['text'],
          cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
          contextWindow: 131072,
          maxTokens: 4096,
        },
      ],
    };
    // Use Ollama as primary model (no fallbacks to cloud providers)
    // To re-enable cloud fallbacks, uncomment the fallbacks line:
    cfg.agents = cfg.agents || {};
    cfg.agents.defaults = cfg.agents.defaults || {};
    cfg.agents.defaults.model = {
      primary: 'ollama/llama3.1',
      fallbacks: ['openai/gpt-5.2'],
    };
    fs.writeFileSync('$CONFIG_FILE', JSON.stringify(cfg, null, 2));
    console.log('Config updated with port=$GATEWAY_PORT, bind=lan, plugins enabled, ollama primary');
  " || echo "Warning: Could not update config, relying on env vars"
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

# Verify Ollama connectivity
echo "Checking Ollama endpoint..."
curl -sf --max-time 10 https://desktop-0qhu65q.taila384a4.ts.net/v1/models && echo "" && echo "Ollama: reachable" || echo "WARNING: Ollama endpoint not reachable from Render"

# Start the gateway
# Set port and bind via env vars (takes precedence over config)
export OPENCLAW_GATEWAY_PORT="${PORT:-8080}"
export OPENCLAW_GATEWAY_BIND="lan"

# Log startup config for debugging
echo "Starting gateway:"
echo "  PORT=$PORT"
echo "  OPENCLAW_GATEWAY_PORT=$OPENCLAW_GATEWAY_PORT"
echo "  OPENCLAW_GATEWAY_BIND=$OPENCLAW_GATEWAY_BIND"
echo "  Command: node dist/index.js gateway --port $OPENCLAW_GATEWAY_PORT --bind lan --allow-unconfigured"

exec node --max-old-space-size=768 dist/index.js gateway --port "$OPENCLAW_GATEWAY_PORT" --bind lan --allow-unconfigured
