#!/bin/bash
# Docker/Podman entrypoint: bootstrap config files into the mounted volume, then run hermes.
set -e

HERMES_HOME="${HERMES_HOME:-/opt/data}"
INSTALL_DIR="/opt/hermes"

# --- Privilege dropping via gosu ---
# When started as root (the default for Docker, or fakeroot in rootless Podman),
# optionally remap the hermes user/group to match host-side ownership, fix volume
# permissions, then re-exec as hermes.
if [ "$(id -u)" = "0" ]; then
    if [ -n "$HERMES_UID" ] && [ "$HERMES_UID" != "$(id -u hermes)" ]; then
        echo "Changing hermes UID to $HERMES_UID"
        usermod -u "$HERMES_UID" hermes
    fi

    if [ -n "$HERMES_GID" ] && [ "$HERMES_GID" != "$(id -g hermes)" ]; then
        echo "Changing hermes GID to $HERMES_GID"
        # -o allows non-unique GID (e.g. macOS GID 20 "staff" may already exist
        # as "dialout" in the Debian-based container image)
        groupmod -o -g "$HERMES_GID" hermes 2>/dev/null || true
    fi

    actual_hermes_uid=$(id -u hermes)
    if [ "$(stat -c %u "$HERMES_HOME" 2>/dev/null)" != "$actual_hermes_uid" ]; then
        echo "$HERMES_HOME is not owned by $actual_hermes_uid, fixing"
        # In rootless Podman the container's "root" is mapped to an unprivileged
        # host UID — chown will fail.  That's fine: the volume is already owned
        # by the mapped user on the host side.
        chown -R hermes:hermes "$HERMES_HOME" 2>/dev/null || \
            echo "Warning: chown failed (rootless container?) — continuing anyway"
    fi

    echo "Dropping root privileges"
    exec gosu hermes "$0" "$@"
fi

# --- Running as hermes from here ---
source "${INSTALL_DIR}/.venv/bin/activate"

# --- Optional Bulk Migration ---
# If HERMES_HOME is uninitialized, we can pull in an entire older backup
# (including config.yaml, memories, sessions, etc.)
if [ ! -f "$HERMES_HOME/config.yaml" ]; then
    if [ -n "$HERMES_MIGRATION_URL" ]; then
        echo "Found HERMES_MIGRATION_URL. Downloading migration archive..."
        curl -sL "$HERMES_MIGRATION_URL" -o /tmp/migration.tar.gz || wget -qO /tmp/migration.tar.gz "$HERMES_MIGRATION_URL"
        if [ -f /tmp/migration.tar.gz ]; then
            echo "Extracting archive directly into $HERMES_HOME..."
            # --strip-components=1 handles hermes profile export default.tar.gz which has default/ root
            tar -xzf /tmp/migration.tar.gz -C "$HERMES_HOME" --strip-components=1 || true
            rm -f /tmp/migration.tar.gz
        else
            echo "Warning: Failed to download migration archive from $HERMES_MIGRATION_URL"
        fi
    elif [ -n "$HERMES_MIGRATION_DIR" ] && [ -d "$HERMES_MIGRATION_DIR" ]; then
        echo "Found HERMES_MIGRATION_DIR at $HERMES_MIGRATION_DIR. Copying all files to $HERMES_HOME..."
        cp -pnR "$HERMES_MIGRATION_DIR/"* "$HERMES_HOME/" || true
    fi
fi

# Create essential directory structure.  Cache and platform directories
# (cache/images, cache/audio, platforms/whatsapp, etc.) are created on
# demand by the application — don't pre-create them here so new installs
# get the consolidated layout from get_hermes_dir().
# The "home/" subdirectory is a per-profile HOME for subprocesses (git,
# ssh, gh, npm …).  Without it those tools write to /root which is
# ephemeral and shared across profiles.  See issue #4426.
mkdir -p "$HERMES_HOME"/{cron,sessions,logs,hooks,memories,skills,skins,plans,workspace,home}

# Setup SSH if requested via environment variables
if [ -n "$SSH_PASSWORD" ] || [ -n "$SSH_PUBKEY" ]; then
    mkdir -p /run/sshd
    if [ -n "$SSH_PASSWORD" ]; then
        echo "root:$SSH_PASSWORD" | chpasswd
        sed -i 's/#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
        sed -i 's/#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
    fi
    if [ -n "$SSH_PUBKEY" ]; then
        mkdir -p /root/.ssh
        echo "$SSH_PUBKEY" >> /root/.ssh/authorized_keys
        chmod 700 /root/.ssh
        chmod 600 /root/.ssh/authorized_keys
        sed -i 's/#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
    fi
    /usr/sbin/sshd
    echo "SSH server started."
fi

# .env
if [ ! -f "$HERMES_HOME/.env" ]; then
    cp "$INSTALL_DIR/.env.example" "$HERMES_HOME/.env"
    
    # Auto-populate .env from Akash Environment Variables if they exist
    echo "Populating .env from environment variables..."
    [ -n "$TELEGRAM_BOT_TOKEN" ] && echo "TELEGRAM_BOT_TOKEN=\"$TELEGRAM_BOT_TOKEN\"" >> "$HERMES_HOME/.env"
    [ -n "$TELEGRAM_ALLOWED_USERS" ] && echo "TELEGRAM_ALLOWED_USERS=\"$TELEGRAM_ALLOWED_USERS\"" >> "$HERMES_HOME/.env"
    [ -n "$OPENAI_API_KEY" ] && echo "OPENAI_API_KEY=\"$OPENAI_API_KEY\"" >> "$HERMES_HOME/.env"
    [ -n "$OPENAI_BASE_URL" ] && echo "OPENAI_BASE_URL=\"$OPENAI_BASE_URL\"" >> "$HERMES_HOME/.env"
fi

# config.yaml
if [ ! -f "$HERMES_HOME/config.yaml" ]; then
    cp "$INSTALL_DIR/cli-config.yaml.example" "$HERMES_HOME/config.yaml"

    # Use Python to safely update config.yaml — sed injection can produce
    # malformed YAML which causes HTTP 400 "JSON parse" errors via bad requests.
    python3 - <<PYEOF
import yaml, os, sys

cfg_path = "$HERMES_HOME/config.yaml"
with open(cfg_path, "r", encoding="utf-8") as f:
    cfg = yaml.safe_load(f) or {}

model_cfg = cfg.get("model", {})
if not isinstance(model_cfg, dict):
    model_cfg = {}

custom_model = os.getenv("LLM_MODEL", "").strip()
base_url     = os.getenv("OPENAI_BASE_URL", "").strip().rstrip("/")
api_key      = os.getenv("OPENAI_API_KEY", "").strip()

if custom_model:
    model_cfg["default"]  = custom_model
    model_cfg["provider"] = "custom"
if base_url:
    model_cfg["base_url"] = base_url
if api_key:
    model_cfg["api_key"] = api_key

cfg["model"] = model_cfg

with open(cfg_path, "w", encoding="utf-8") as f:
    yaml.dump(cfg, f, default_flow_style=False, allow_unicode=True)

if custom_model or base_url or api_key:
    print(f"Config updated: model={custom_model or '(unchanged)'}, base_url={base_url or '(unchanged)'}")
PYEOF
fi

# SOUL.md
if [ ! -f "$HERMES_HOME/SOUL.md" ]; then
    cp "$INSTALL_DIR/docker/SOUL.md" "$HERMES_HOME/SOUL.md"
fi
    
# Sync bundled skills (manifest-based so user edits are preserved)
if [ -d "$INSTALL_DIR/skills" ]; then
    python3 "$INSTALL_DIR/tools/skills_sync.py"
fi

# Auto-detect gateway mode: if any messaging platform token is set and the
# caller did not explicitly pass a subcommand, run the gateway in the
# foreground (hermes gateway) instead of the interactive CLI which exits
# immediately when stdin is not a terminal.
if [ $# -eq 0 ] && {
    [ -n "$TELEGRAM_BOT_TOKEN" ] ||
    [ -n "$DISCORD_BOT_TOKEN" ] ||
    [ -n "$SLACK_BOT_TOKEN" ] ||
    [ -n "$SLACK_APP_TOKEN" ] ||
    [ -n "$WHATSAPP_ENABLED" ] ||
    [ -n "$SIGNAL_HTTP_URL" ] ||
    [ -n "$MATRIX_HOMESERVER" ] ||
    [ -n "$DINGTALK_CLIENT_ID" ] ||
    [ -n "$FEISHU_APP_ID" ] ||
    [ -n "$WECOM_BOT_ID" ] ||
    [ -n "$TWILIO_ACCOUNT_SID" ] ||
    [ -n "$EMAIL_ADDRESS" ]; }; then
    exec hermes gateway
fi

exec hermes "$@"
