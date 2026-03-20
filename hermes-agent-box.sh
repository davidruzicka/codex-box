#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# hermes-agent-box — single-file runner for Hermes Agent in Docker
# ------------------------------------------------------------

BASE_IMAGE_NAME="${HERMES_AGENT_IMAGE:-hermes-agent-box:py311}"
PROJECT_DIR="${HERMES_AGENT_PROJECT_DIR:-$PWD}"
HERMES_AGENT_GIT_REF="${HERMES_AGENT_GIT_REF:-main}"
HERMES_DIR_HOST="${HERMES_DIR_HOST:-$HOME/.hermes}"
CODEX_DIR_HOST="${CODEX_DIR_HOST:-$HOME/.codex}"
HERMES_HISTORY_HOST="${HERMES_HISTORY_HOST:-$HOME/.hermes_history}"
HERMES_AGENT_BOX_CONFIG_DIR="${HERMES_AGENT_BOX_CONFIG_DIR:-$HOME/.hermes-agent-box}"
HERMES_AGENT_BOX_CONFIG_FILE="$HERMES_AGENT_BOX_CONFIG_DIR/config"

HOME_CONT="/home/node"
HERMES_DIR_CONT="${HOME_CONT}/.hermes"
CODEX_DIR_CONT="${HOME_CONT}/.codex"
HERMES_HISTORY_CONT="${HOME_CONT}/.hermes_history"
WORKDIR_CONT="/workspace"

BUILD=0
EXTRA_ENV_ARGS=()
SESSION_ENV_ARGS=()
SESSION_DOCKER_ARGS=()
DNS_MODE=""
DNS_IP=""
DNS_ARGS=()
BUILD_NETWORK_ARGS=()
SAVE_CONFIG=0
TARGET_IMAGE_NAME="$BASE_IMAGE_NAME"

usage() {
  cat <<'EOF'
Usage:
  ./hermes-agent-box.sh [--build] [--project <path>] [-e VAR[=value]]... [-d local|-d <ip>] [-s] -- [hermes-args...]

Examples:
  ./hermes-agent-box.sh -- --help
  ./hermes-agent-box.sh --build -- setup
  ./hermes-agent-box.sh --project /path/to/project -- chat
  ./hermes-agent-box.sh -e OPENROUTER_API_KEY=sk-or-xxx -e HTTP_PROXY=http://proxy:3128 -- model

Options:
  --build          Rebuild the image explicitly
  --project PATH   Project directory to mount (default: current directory)
  -e VAR[=value]   Pass environment variable to container (can be used multiple times)
  -d MODE|IP       DNS mode: 'local' uses host resolver, or pass an IP address
  -s               Save -d and -e settings to ~/.hermes-agent-box/config

Build behavior:
  Image is built only when:
  1) image does not exist, or
  2) --build is provided.

Persistent context mounts:
  ~/.hermes         -> /home/node/.hermes
  ~/.codex          -> /home/node/.codex
  ~/.hermes_history -> /home/node/.hermes_history

Display/Session passthrough:
  If an X11 or Wayland session is detected, the script forwards needed
  env vars and sockets for desktop integrations.
EOF
}

set_env_arg() {
  local kv="$1"
  local name="${kv%%=*}"
  local new_args=()
  local i=0

  while [[ $i -lt ${#EXTRA_ENV_ARGS[@]} ]]; do
    if [[ "${EXTRA_ENV_ARGS[i]}" == "-e" ]]; then
      local val="${EXTRA_ENV_ARGS[i+1]:-}"
      local existing_name="${val%%=*}"
      if [[ "$existing_name" == "$name" ]]; then
        i=$((i+2))
        continue
      fi
      new_args+=("-e" "$val")
      i=$((i+2))
    else
      new_args+=("${EXTRA_ENV_ARGS[i]}")
      i=$((i+1))
    fi
  done

  EXTRA_ENV_ARGS=("${new_args[@]}")
  EXTRA_ENV_ARGS+=("-e" "$kv")
}

load_config() {
  [[ -f "$HERMES_AGENT_BOX_CONFIG_FILE" ]] || return 0

  while IFS= read -r line; do
    line="${line%%$'\r'}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    case "$line" in
      DNS_MODE=*) DNS_MODE="${line#DNS_MODE=}" ;;
      DNS_IP=*) DNS_IP="${line#DNS_IP=}" ;;
      ENV\ *) set_env_arg "${line#ENV }" ;;
    esac
  done < "$HERMES_AGENT_BOX_CONFIG_FILE"
}

save_config() {
  mkdir -p "$HERMES_AGENT_BOX_CONFIG_DIR"
  {
    echo "# hermes-agent-box config"
    echo "DNS_MODE=$DNS_MODE"
    echo "DNS_IP=$DNS_IP"
    local i=0
    while [[ $i -lt ${#EXTRA_ENV_ARGS[@]} ]]; do
      if [[ "${EXTRA_ENV_ARGS[i]}" == "-e" ]]; then
        echo "ENV ${EXTRA_ENV_ARGS[i+1]}"
        i=$((i+2))
      else
        i=$((i+1))
      fi
    done
  } > "$HERMES_AGENT_BOX_CONFIG_FILE"
}

load_config

# ------------------ argument parsing ------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --build)
      BUILD=1; shift ;;
    --project)
      PROJECT_DIR="$2"; shift 2 ;;
    -e)
      if [[ -n "${2:-}" ]]; then
        set_env_arg "$2"
        shift 2
      else
        echo "Error: -e requires an argument (VAR or VAR=value)" >&2
        exit 1
      fi
      ;;
    -d)
      if [[ -n "${2:-}" ]]; then
        if [[ "$2" == "local" ]]; then
          DNS_MODE="local"
          DNS_IP=""
        else
          DNS_IP="$2"
          DNS_MODE=""
        fi
        shift 2
      else
        echo "Error: -d requires an argument (local or IP)" >&2
        exit 1
      fi
      ;;
    -s)
      SAVE_CONFIG=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
    --)
      shift; break ;;
    *)
      break ;;
  esac
done

# ------------------ sanity checks ------------------
[[ -d "$PROJECT_DIR" ]] || { echo "Error: project directory does not exist: $PROJECT_DIR" >&2; exit 1; }
mkdir -p "$HERMES_DIR_HOST"
mkdir -p "$CODEX_DIR_HOST"
mkdir -p "$(dirname "$HERMES_HISTORY_HOST")"
touch "$HERMES_HISTORY_HOST"

# ------------------ DNS override ------------------
if [[ "$DNS_MODE" == "local" ]]; then
  if [[ -f /etc/resolv.conf ]]; then
    LOCAL_DNS=$(grep -m1 '^nameserver' /etc/resolv.conf | awk '{print $2}')
    if [[ -n "$LOCAL_DNS" ]]; then
      DNS_ARGS+=(--dns "$LOCAL_DNS")
      BUILD_NETWORK_ARGS+=(--network host)
    else
      echo "Error: could not determine local DNS from /etc/resolv.conf" >&2
      exit 1
    fi
  else
    echo "Error: /etc/resolv.conf not found for local DNS" >&2
    exit 1
  fi
elif [[ -n "$DNS_IP" ]]; then
  DNS_ARGS+=(--dns "$DNS_IP")
fi

# ------------------ inline Dockerfile ------------------
DOCKERFILE=$(cat <<'EOF'
FROM node:24-bookworm AS builder

ARG HERMES_AGENT_GIT_REF=main

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates git openssh-client tini curl wget \
    jq tree less vim \
    locales ncurses-term \
    ripgrep \
    fd-find \
    bat \
    python3 \
    python3-pip \
    python3-venv \
    python3-yaml python3-pytest \
  && ln -sf /usr/bin/python3 /usr/local/bin/python \
  && ln -sf /usr/bin/fdfind /usr/local/bin/fd \
  && ln -sf /usr/bin/batcat /usr/local/bin/bat \
  && rm -rf /var/lib/apt/lists/*

RUN git clone --recurse-submodules https://github.com/NousResearch/hermes-agent.git /opt/hermes-agent \
  && cd /opt/hermes-agent \
  && git checkout "$HERMES_AGENT_GIT_REF" \
  && git submodule update --init --recursive \
  && python3 -m venv /opt/hermes-venv \
  && /opt/hermes-venv/bin/pip install --no-cache-dir -e . \
  && if [ -f /opt/hermes-agent/mini-swe-agent/pyproject.toml ]; then /opt/hermes-venv/bin/pip install --no-cache-dir -e /opt/hermes-agent/mini-swe-agent; fi \
  && if [ -f /opt/hermes-agent/scripts/whatsapp-bridge/package.json ]; then cd /opt/hermes-agent/scripts/whatsapp-bridge && npm install --omit=dev; fi \
  && mkdir -p /opt/hermes-agent/tinker-atropos/logs \
  && rm -rf /opt/hermes-agent/.git /opt/hermes-agent/mini-swe-agent/.git /opt/hermes-agent/tinker-atropos/.git \
  && find /opt/hermes-agent -type d -name '__pycache__' -prune -exec rm -rf {} +

FROM node:24-bookworm

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates git openssh-client tini curl wget \
    jq tree less vim \
  locales ncurses-term \
    ripgrep \
    fd-find \
    bat \
    python3 \
    python3-pip \
    python3-venv \
    python3-yaml python3-pytest \
  && ln -sf /usr/bin/python3 /usr/local/bin/python \
  && ln -sf /usr/bin/fdfind /usr/local/bin/fd \
  && ln -sf /usr/bin/batcat /usr/local/bin/bat \
  && rm -rf /var/lib/apt/lists/*

COPY --from=builder --chown=node:node /opt/hermes-agent /opt/hermes-agent
COPY --from=builder --chown=node:node /opt/hermes-venv /opt/hermes-venv

ENV HOME=/home/node \
    HERMES_HOME=/home/node/.hermes \
  LANG=C.UTF-8 \
  LC_ALL=C.UTF-8 \
    PATH=/opt/hermes-venv/bin:$PATH \
    PYTHONPATH=/opt/hermes-agent
WORKDIR /workspace
USER node

ENTRYPOINT ["/usr/bin/tini","--","hermes"]
EOF
)

# ------------------ build image ------------------
image_exists() {
  docker image inspect "$1" >/dev/null 2>&1
}

if [[ "$BUILD" -eq 1 ]] || ! image_exists "$TARGET_IMAGE_NAME"; then
  echo "▶ Building Docker image: $TARGET_IMAGE_NAME"
  docker build "${BUILD_NETWORK_ARGS[@]}" --build-arg "HERMES_AGENT_GIT_REF=$HERMES_AGENT_GIT_REF" -t "$TARGET_IMAGE_NAME" - <<EOF
$DOCKERFILE
EOF
fi

# ------------------ env passthrough ------------------
ENV_ARGS=()
for var in OPENAI_API_KEY OPENAI_BASE_URL OPENROUTER_API_KEY ANTHROPIC_API_KEY GOOGLE_API_KEY HTTP_PROXY HTTPS_PROXY NO_PROXY \
           TERM COLORTERM TERM_PROGRAM TERM_PROGRAM_VERSION LANG LC_ALL LC_CTYPE; do
  [[ -n "${!var:-}" ]] && ENV_ARGS+=(-e "$var=${!var}")
done

# Add extra environment variables from -e flags
ENV_ARGS+=("${EXTRA_ENV_ARGS[@]}")
ENV_ARGS+=(
  -e "TERM=${TERM:-xterm-256color}"
  -e "LANG=${LANG:-C.UTF-8}"
  -e "LC_ALL=${LC_ALL:-C.UTF-8}"
)

# ------------------ X11 / Wayland passthrough ------------------
# X11 session support
if [[ -n "${DISPLAY:-}" ]]; then
  SESSION_ENV_ARGS+=(-e "DISPLAY=$DISPLAY")

  if [[ -d /tmp/.X11-unix ]]; then
    SESSION_DOCKER_ARGS+=(-v /tmp/.X11-unix:/tmp/.X11-unix:rw)
  fi

  if [[ -n "${XAUTHORITY:-}" && -f "${XAUTHORITY}" ]]; then
    SESSION_ENV_ARGS+=(-e "XAUTHORITY=$XAUTHORITY")
    SESSION_DOCKER_ARGS+=(-v "$XAUTHORITY:$XAUTHORITY:ro")
  elif [[ -f "$HOME/.Xauthority" ]]; then
    SESSION_ENV_ARGS+=(-e "XAUTHORITY=$HOME/.Xauthority")
    SESSION_DOCKER_ARGS+=(-v "$HOME/.Xauthority:$HOME/.Xauthority:ro")
  fi
fi

# Wayland session support
if [[ -n "${WAYLAND_DISPLAY:-}" && -n "${XDG_RUNTIME_DIR:-}" ]]; then
  WAYLAND_SOCKET_HOST="$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY"
  if [[ -S "$WAYLAND_SOCKET_HOST" ]]; then
    WAYLAND_RUNTIME_CONT="/tmp"
    SESSION_DOCKER_ARGS+=(-v "$WAYLAND_SOCKET_HOST:$WAYLAND_RUNTIME_CONT/$WAYLAND_DISPLAY")
    SESSION_ENV_ARGS+=(
      -e "WAYLAND_DISPLAY=$WAYLAND_DISPLAY"
      -e "XDG_RUNTIME_DIR=$WAYLAND_RUNTIME_CONT"
    )

    if [[ -S "$XDG_RUNTIME_DIR/bus" ]]; then
      SESSION_DOCKER_ARGS+=(-v "$XDG_RUNTIME_DIR/bus:$WAYLAND_RUNTIME_CONT/bus")
      SESSION_ENV_ARGS+=(-e "DBUS_SESSION_BUS_ADDRESS=unix:path=$WAYLAND_RUNTIME_CONT/bus")
    fi

    [[ -n "${XDG_SESSION_TYPE:-}" ]] && SESSION_ENV_ARGS+=(-e "XDG_SESSION_TYPE=$XDG_SESSION_TYPE")
  fi
fi

# ------------------ run ------------------
DOCKER_ARGS=(run --rm --add-host=host.docker.internal:host-gateway)
[[ -t 0 ]] && [[ -t 1 ]] && DOCKER_ARGS+=(-it)

if [[ "$SAVE_CONFIG" -eq 1 ]]; then
  save_config
fi

# systemd user service management must run on the host, not inside the container.
if [[ "${1:-}" == "gateway" ]]; then
  case "${2:-}" in
    install|start|stop|restart|status)
      echo "Error: 'hermes gateway ${2}' cannot run inside hermes-agent-box." >&2
      echo "Reason: this container does not run systemd, so 'systemctl --user' is unavailable." >&2
      echo "Run Hermes gateway in the foreground inside Docker with:" >&2
      echo "  ./hermes-agent-box.sh gateway" >&2
      echo "For background Docker gateway management, use:" >&2
      echo "  ./hermes-agent-gateway-box.sh start" >&2
      echo "Or install/manage a service on the host instead of inside the container." >&2
      exit 1
      ;;
  esac
fi

exec docker "${DOCKER_ARGS[@]}" \
  "${DNS_ARGS[@]}" \
  "${ENV_ARGS[@]}" \
  "${SESSION_ENV_ARGS[@]}" \
  "${SESSION_DOCKER_ARGS[@]}" \
  -e HOME="$HOME_CONT" \
  -e HERMES_HOME="$HERMES_DIR_CONT" \
  -v "$HERMES_DIR_HOST:$HERMES_DIR_CONT" \
  -v "$CODEX_DIR_HOST:$CODEX_DIR_CONT" \
  -v "$HERMES_HISTORY_HOST:$HERMES_HISTORY_CONT" \
  -v "$PROJECT_DIR:$WORKDIR_CONT" \
  -w "$WORKDIR_CONT" \
  "$TARGET_IMAGE_NAME" \
  "$@"
