#!/bin/bash
# Startup script for Moltbot in Cloudflare Sandbox
# Version: 2026-01-31-v41-groq-simplified
# 
# Why Moltbot? It provides persistent conversation memory across sessions.
# This complexity is worth it if you want the bot to remember past conversations.
# 
# This script:
# 1. Restores config from R2 backup if available
# 2. Configures moltbot from environment variables (Groq-focused)
# 3. Starts a background sync to backup config to R2
# 4. Starts the gateway

set -e

# Check if clawdbot gateway is already running - bail early if so
# Note: CLI is still named "clawdbot" until upstream renames it
if pgrep -f "clawdbot gateway" > /dev/null 2>&1; then
    echo "Moltbot gateway is already running, exiting."
    exit 0
fi

# Paths (clawdbot paths are used internally - upstream hasn't renamed yet)
CONFIG_DIR="/root/.clawdbot"
CONFIG_FILE="$CONFIG_DIR/clawdbot.json"
TEMPLATE_DIR="/root/.clawdbot-templates"
TEMPLATE_FILE="$TEMPLATE_DIR/moltbot.json.template"
BACKUP_DIR="/data/moltbot"

echo "Config directory: $CONFIG_DIR"
echo "Backup directory: $BACKUP_DIR"

# Create config directory
mkdir -p "$CONFIG_DIR"

# ============================================================
# RESTORE FROM R2 BACKUP
# ============================================================
# Check if R2 backup exists by looking for clawdbot.json
# The BACKUP_DIR may exist but be empty if R2 was just mounted
# Note: backup structure is $BACKUP_DIR/clawdbot/ and $BACKUP_DIR/skills/

# Helper function to check if R2 backup is newer than local
should_restore_from_r2() {
    local R2_SYNC_FILE="$BACKUP_DIR/.last-sync"
    local LOCAL_SYNC_FILE="$CONFIG_DIR/.last-sync"
    
    # If no R2 sync timestamp, don't restore
    if [ ! -f "$R2_SYNC_FILE" ]; then
        echo "No R2 sync timestamp found, skipping restore"
        return 1
    fi
    
    # If no local sync timestamp, restore from R2
    if [ ! -f "$LOCAL_SYNC_FILE" ]; then
        echo "No local sync timestamp, will restore from R2"
        return 0
    fi
    
    # Compare timestamps
    R2_TIME=$(cat "$R2_SYNC_FILE" 2>/dev/null)
    LOCAL_TIME=$(cat "$LOCAL_SYNC_FILE" 2>/dev/null)
    
    echo "R2 last sync: $R2_TIME"
    echo "Local last sync: $LOCAL_TIME"
    
    # Convert to epoch seconds for comparison
    R2_EPOCH=$(date -d "$R2_TIME" +%s 2>/dev/null || echo "0")
    LOCAL_EPOCH=$(date -d "$LOCAL_TIME" +%s 2>/dev/null || echo "0")
    
    if [ "$R2_EPOCH" -gt "$LOCAL_EPOCH" ]; then
        echo "R2 backup is newer, will restore"
        return 0
    else
        echo "Local data is newer or same, skipping restore"
        return 1
    fi
}

if [ -f "$BACKUP_DIR/clawdbot/clawdbot.json" ]; then
    if should_restore_from_r2; then
        echo "Restoring from R2 backup at $BACKUP_DIR/clawdbot..."
        cp -a "$BACKUP_DIR/clawdbot/." "$CONFIG_DIR/"
        # Copy the sync timestamp to local so we know what version we have
        cp -f "$BACKUP_DIR/.last-sync" "$CONFIG_DIR/.last-sync" 2>/dev/null || true
        echo "Restored config from R2 backup"
    fi
elif [ -f "$BACKUP_DIR/clawdbot.json" ]; then
    # Legacy backup format (flat structure)
    if should_restore_from_r2; then
        echo "Restoring from legacy R2 backup at $BACKUP_DIR..."
        cp -a "$BACKUP_DIR/." "$CONFIG_DIR/"
        cp -f "$BACKUP_DIR/.last-sync" "$CONFIG_DIR/.last-sync" 2>/dev/null || true
        echo "Restored config from legacy R2 backup"
    fi
elif [ -d "$BACKUP_DIR" ]; then
    echo "R2 mounted at $BACKUP_DIR but no backup data found yet"
else
    echo "R2 not mounted, starting fresh"
fi

# Restore skills from R2 backup if available (only if R2 is newer)
SKILLS_DIR="/root/clawd/skills"
if [ -d "$BACKUP_DIR/skills" ] && [ "$(ls -A $BACKUP_DIR/skills 2>/dev/null)" ]; then
    if should_restore_from_r2; then
        echo "Restoring skills from $BACKUP_DIR/skills..."
        mkdir -p "$SKILLS_DIR"
        cp -a "$BACKUP_DIR/skills/." "$SKILLS_DIR/"
        echo "Restored skills from R2 backup"
    fi
fi

# If config file still doesn't exist, create from template
if [ ! -f "$CONFIG_FILE" ]; then
    echo "No existing config found, initializing from template..."
    if [ -f "$TEMPLATE_FILE" ]; then
        cp "$TEMPLATE_FILE" "$CONFIG_FILE"
    else
        # Create minimal config if template doesn't exist
        cat > "$CONFIG_FILE" << 'EOFCONFIG'
{
  "agents": {
    "defaults": {
      "workspace": "/root/clawd"
    }
  },
  "gateway": {
    "port": 18789,
    "mode": "local"
  }
}
EOFCONFIG
    fi
else
    echo "Using existing config"
fi

# ============================================================
# UPDATE CONFIG FROM ENVIRONMENT VARIABLES
# ============================================================
node << EOFNODE
const fs = require('fs');

const configPath = '/root/.clawdbot/clawdbot.json';
console.log('Updating config at:', configPath);
let config = {};

try {
    config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
} catch (e) {
    console.log('Starting with empty config');
}

// Ensure nested objects exist
config.agents = config.agents || {};
config.agents.defaults = config.agents.defaults || {};
config.agents.defaults.model = config.agents.defaults.model || {};
config.gateway = config.gateway || {};
config.channels = config.channels || {};

// Clean up any broken anthropic provider config from previous runs
// (older versions didn't include required 'name' field)
if (config.models?.providers?.anthropic?.models) {
    const hasInvalidModels = config.models.providers.anthropic.models.some(m => !m.name);
    if (hasInvalidModels) {
        console.log('Removing broken anthropic provider config (missing model names)');
        delete config.models.providers.anthropic;
    }
}

// Clean up any custom google provider config from previous runs
// (the built-in google provider should be used instead)
if (config.models?.providers?.google) {
    console.log('Removing custom google provider config (use built-in provider instead)');
    delete config.models.providers.google;
}

// Clean up old google model allowlist entries
if (config.agents?.defaults?.models) {
    const googleModels = Object.keys(config.agents.defaults.models).filter(k => k.startsWith('google/'));
    if (googleModels.length > 0) {
        console.log('Removing old google model allowlist entries');
        googleModels.forEach(m => delete config.agents.defaults.models[m]);
    }
}

// Clean up any Groq provider config from previous runs
// (recreated fresh below with correct settings)
if (config.models?.providers?.groq) {
    console.log('Removing old groq provider config (will be recreated fresh)');
    delete config.models.providers.groq;
}

// Clean up old groq model allowlist entries
if (config.agents?.defaults?.models) {
    const groqModels = Object.keys(config.agents.defaults.models).filter(k => k.startsWith('groq/'));
    if (groqModels.length > 0) {
        console.log('Removing old groq model allowlist entries');
        groqModels.forEach(m => delete config.agents.defaults.models[m]);
    }
}



// Gateway configuration
config.gateway.port = 18789;
config.gateway.mode = 'local';
config.gateway.trustedProxies = ['10.1.0.0'];

// Set gateway token if provided
if (process.env.CLAWDBOT_GATEWAY_TOKEN) {
    config.gateway.auth = config.gateway.auth || {};
    config.gateway.auth.token = process.env.CLAWDBOT_GATEWAY_TOKEN;
}

// Allow insecure auth for dev mode
if (process.env.CLAWDBOT_DEV_MODE === 'true') {
    config.gateway.controlUi = config.gateway.controlUi || {};
    config.gateway.controlUi.allowInsecureAuth = true;
}

// Telegram configuration
if (process.env.TELEGRAM_BOT_TOKEN) {
    config.channels.telegram = config.channels.telegram || {};
    config.channels.telegram.botToken = process.env.TELEGRAM_BOT_TOKEN;
    config.channels.telegram.enabled = true;
    config.channels.telegram.dmPolicy = process.env.TELEGRAM_DM_POLICY || 'pairing';
    // Prevent context from growing unbounded in long-running Telegram DM threads.
    // This is especially important when switching from a huge-context model (e.g. Gemini)
    // to a smaller-context model (e.g. many Groq-hosted models), which can otherwise
    // trigger "Context overflow: prompt too large for the model".
    config.channels.telegram.dmHistoryLimit = 30;
}

// Discord configuration
if (process.env.DISCORD_BOT_TOKEN) {
    config.channels.discord = config.channels.discord || {};
    config.channels.discord.token = process.env.DISCORD_BOT_TOKEN;
    config.channels.discord.enabled = true;
    config.channels.discord.dmPolicy = process.env.DISCORD_DM_POLICY || 'pairing';
}

// Slack configuration
if (process.env.SLACK_BOT_TOKEN && process.env.SLACK_APP_TOKEN) {
    config.channels.slack = config.channels.slack || {};
    config.channels.slack.botToken = process.env.SLACK_BOT_TOKEN;
    config.channels.slack.appToken = process.env.SLACK_APP_TOKEN;
    config.channels.slack.enabled = true;
}

// ============================================================
// MODEL PROVIDER CONFIGURATION
// ============================================================
// Simplified: Focus on Groq for fast inference with persistent memory.
// Moltbot provides conversation memory/persistence across sessions, which is
// why we're using it instead of a simple bot. The complexity is worth it for memory.

const baseUrl = (process.env.AI_GATEWAY_BASE_URL || process.env.ANTHROPIC_BASE_URL || '').replace(/\/+$/, '');
const isGroqGateway = baseUrl.endsWith('/groq');
const hasGroqKey = !!process.env.GROQ_API_KEY;

// Validate Groq is configured
if (!hasGroqKey && !isGroqGateway) {
    console.error('ERROR: GROQ_API_KEY or AI_GATEWAY_BASE_URL (pointing to /groq) must be set');
    console.error('Without a model provider, Moltbot cannot respond to messages.');
    process.exit(1);
}

// Configure Groq provider
console.log('Configuring Groq provider for fast inference');
const groqBaseUrl = isGroqGateway ? baseUrl : 'https://api.groq.com/openai/v1';
console.log('Groq base URL:', groqBaseUrl);

config.models = config.models || {};
config.models.providers = config.models.providers || {};
config.models.providers.groq = {
    baseUrl: groqBaseUrl,
    // Groq exposes an OpenAI-compatible *completions* API (chat/completions),
    // not the OpenAI "Responses" API. Using openai-responses causes hangs/timeouts.
    api: 'openai-completions',
    models: [
        // Context windows from Groq docs (console.groq.com/docs/models)
        { id: 'moonshotai/kimi-k2-instruct-0905', name: 'Kimi K2', contextWindow: 262144 },
        { id: 'llama-3.3-70b-versatile', name: 'Llama 3.3 70B', contextWindow: 131072 },
        { id: 'llama-3.1-8b-instant', name: 'Llama 3.1 8B Instant', contextWindow: 131072 },
    ]
};

if (hasGroqKey) {
    config.models.providers.groq.apiKey = process.env.GROQ_API_KEY;
    console.log('Groq API key: SET (from GROQ_API_KEY env var)');
} else {
    console.log('Groq API key: Will use AI Gateway authentication');
}

// Configure model allowlist and default
config.agents.defaults.models = config.agents.defaults.models || {};
config.agents.defaults.models['groq/moonshotai/kimi-k2-instruct-0905'] = { alias: 'Kimi K2' };
config.agents.defaults.models['groq/llama-3.3-70b-versatile'] = { alias: 'Llama 3.3 70B' };
config.agents.defaults.models['groq/llama-3.1-8b-instant'] = { alias: 'Llama 3.1 8B' };

// Default to production model (larger context, more stable than preview Kimi)
config.agents.defaults.model.primary = 'groq/llama-3.3-70b-versatile';
console.log('Default model:', config.agents.defaults.model.primary);

// Write updated config
fs.writeFileSync(configPath, JSON.stringify(config, null, 2));
console.log('Configuration updated successfully');
console.log('Config:', JSON.stringify(config, null, 2));
EOFNODE

# ============================================================
# CONFIGURE GIT CREDENTIALS
# ============================================================
if [ -n "$GITHUB_TOKEN" ]; then
    echo "Configuring git credentials for GitHub..."
    git config --global credential.helper store
    git config --global user.email "moltbot@localhost"
    git config --global user.name "Moltbot"
    # Store credentials for GitHub
    echo "https://x-access-token:${GITHUB_TOKEN}@github.com" > ~/.git-credentials
    chmod 600 ~/.git-credentials
    echo "GitHub credentials configured"
fi

# ============================================================
# START GATEWAY
# ============================================================
# Note: R2 backup sync is handled by the Worker's cron trigger
echo "Starting Moltbot Gateway..."
echo "Gateway will be available on port 18789"

# Clean up stale lock files
rm -f /tmp/clawdbot-gateway.lock 2>/dev/null || true
rm -f "$CONFIG_DIR/gateway.lock" 2>/dev/null || true

BIND_MODE="lan"
echo "Dev mode: ${CLAWDBOT_DEV_MODE:-false}, Bind mode: $BIND_MODE"

if [ -n "$CLAWDBOT_GATEWAY_TOKEN" ]; then
    echo "Starting gateway with token auth..."
    exec clawdbot gateway --port 18789 --verbose --allow-unconfigured --bind "$BIND_MODE" --token "$CLAWDBOT_GATEWAY_TOKEN"
else
    echo "Starting gateway with device pairing (no token)..."
    exec clawdbot gateway --port 18789 --verbose --allow-unconfigured --bind "$BIND_MODE"
fi
