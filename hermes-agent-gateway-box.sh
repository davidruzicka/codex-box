#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# hermes-agent-gateway-box — background Hermes gateway in Docker
# ------------------------------------------------------------

BASE_IMAGE_NAME="${HERMES_AGENT_IMAGE:-hermes-agent-box:py311}"
CONTAINER_NAME="${HERMES_GATEWAY_CONTAINER_NAME:-hermes-agent-gateway}"
PROJECT_DIR="${HERMES_AGENT_PROJECT_DIR:-$PWD}"
HERMES_AGENT_GIT_REF="${HERMES_AGENT_GIT_REF:-main}"
HERMES_DIR_HOST="${HERMES_DIR_HOST:-$HOME/.hermes}"
CODEX_DIR_HOST="${CODEX_DIR_HOST:-$HOME/.codex}"
HERMES_HISTORY_HOST="${HERMES_HISTORY_HOST:-$HOME/.hermes_history}"
HERMES_GATEWAY_BOX_CONFIG_DIR="${HERMES_GATEWAY_BOX_CONFIG_DIR:-$HOME/.hermes-agent-gateway-box}"
HERMES_GATEWAY_BOX_CONFIG_FILE="$HERMES_GATEWAY_BOX_CONFIG_DIR/config"
HERMES_GATEWAY_TMP_DIR_HOST="${HERMES_GATEWAY_TMP_DIR_HOST:-$HERMES_GATEWAY_BOX_CONFIG_DIR/tmp}"

HOME_CONT="/home/node"
HERMES_DIR_CONT="${HOME_CONT}/.hermes"
CODEX_DIR_CONT="${HOME_CONT}/.codex"
HERMES_HISTORY_CONT="${HOME_CONT}/.hermes_history"
WORKDIR_CONT="/workspace"

BUILD=0
EXTRA_ENV_ARGS=()
DNS_MODE=""
DNS_IP=""
DNS_ARGS=()
BUILD_NETWORK_ARGS=()
SAVE_CONFIG=0
ACTION="start"
TARGET_IMAGE_NAME="$BASE_IMAGE_NAME"
NETWORK_HOST=0

usage() {
  cat <<'EOF'
Usage:
  ./hermes-agent-gateway-box.sh [--build] [--network-host] [--project <path>] [-e VAR[=value]]... [-d local|-d <ip>] [-s] [start|stop|restart|status|logs|rm]

Examples:
  ./hermes-agent-gateway-box.sh
  ./hermes-agent-gateway-box.sh --build start
  ./hermes-agent-gateway-box.sh logs
  ./hermes-agent-gateway-box.sh stop

Actions:
  start    Start gateway container in background (default)
  stop     Stop the gateway container
  restart  Recreate and start the gateway container
  status   Show container status
  logs     Follow gateway logs
  rm       Remove the gateway container

Options:
  --build          Rebuild the image explicitly
  --network-host   Use host networking (workaround when bridge cannot reach host services)
  --project PATH   Project directory to mount (default: current directory)
  -e VAR[=value]   Pass environment variable to container (can be used multiple times)
  -d MODE|IP       DNS mode: 'local' uses host resolver, or pass an IP address
  -s               Save -d and -e settings to ~/.hermes-agent-gateway-box/config

Networking mode tips:
  Use default bridge mode when container-to-container networking is needed.
  Use --network-host when host.docker.internal to host services times out/refuses.

Persistent context mounts:
  ~/.hermes         -> /home/node/.hermes
  ~/.codex          -> /home/node/.codex
  ~/.hermes_history -> /home/node/.hermes_history
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
  [[ -f "$HERMES_GATEWAY_BOX_CONFIG_FILE" ]] || return 0

  while IFS= read -r line; do
    line="${line%%$'\r'}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    case "$line" in
      DNS_MODE=*) DNS_MODE="${line#DNS_MODE=}" ;;
      DNS_IP=*) DNS_IP="${line#DNS_IP=}" ;;
      ENV\ *) set_env_arg "${line#ENV }" ;;
    esac
  done < "$HERMES_GATEWAY_BOX_CONFIG_FILE"
}

save_config() {
  mkdir -p "$HERMES_GATEWAY_BOX_CONFIG_DIR"
  {
    echo "# hermes-agent-gateway-box config"
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
  } > "$HERMES_GATEWAY_BOX_CONFIG_FILE"
}

load_config

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build)
      BUILD=1; shift ;;
    --network-host)
      NETWORK_HOST=1; shift ;;
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
    start|stop|restart|status|logs|rm)
      ACTION="$1"; shift ;;
    *)
      echo "Error: unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

[[ -d "$PROJECT_DIR" ]] || { echo "Error: project directory does not exist: $PROJECT_DIR" >&2; exit 1; }
mkdir -p "$HERMES_DIR_HOST"
mkdir -p "$CODEX_DIR_HOST"
mkdir -p "$(dirname "$HERMES_HISTORY_HOST")"
mkdir -p "$HERMES_GATEWAY_TMP_DIR_HOST"
touch "$HERMES_HISTORY_HOST"

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

HOST_GATEWAY_TARGET="${HERMES_AGENT_HOST_GATEWAY_TARGET:-host-gateway}"

DOCKERFILE=$(cat <<'EOF'
FROM node:24-bookworm AS builder

ARG HERMES_AGENT_GIT_REF=main

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates git openssh-client tini curl wget \
  gh \
    hunspell hunspell-cs hunspell-en-us \
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
    gh \
    hunspell hunspell-cs hunspell-en-us \
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

RUN npm install -g lean-ctx-bin \
  && mkdir -p /home/node \
  && HOME=/home/node lean-ctx setup \
  && if [ -d /home/node/.lean-ctx ]; then chown -R node:node /home/node/.lean-ctx; fi

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

image_exists() {
  docker image inspect "$1" >/dev/null 2>&1
}

container_exists() {
  docker container inspect "$CONTAINER_NAME" >/dev/null 2>&1
}

container_is_running() {
  [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null || true)" == "true" ]]
}

build_image() {
  if [[ "$BUILD" -eq 1 ]] || ! image_exists "$TARGET_IMAGE_NAME"; then
    echo "▶ Building Docker image: $TARGET_IMAGE_NAME"
    docker build "${BUILD_NETWORK_ARGS[@]}" --build-arg "HERMES_AGENT_GIT_REF=$HERMES_AGENT_GIT_REF" -t "$TARGET_IMAGE_NAME" - <<EOF
$DOCKERFILE
EOF
  fi
}

ENV_ARGS=()
for var in OPENAI_API_KEY OPENAI_BASE_URL OPENROUTER_API_KEY ANTHROPIC_API_KEY GOOGLE_API_KEY HTTP_PROXY HTTPS_PROXY NO_PROXY \
           TERM COLORTERM TERM_PROGRAM TERM_PROGRAM_VERSION LANG LC_ALL LC_CTYPE; do
  [[ -n "${!var:-}" ]] && ENV_ARGS+=(-e "$var=${!var}")
done
ENV_ARGS+=("${EXTRA_ENV_ARGS[@]}")
ENV_ARGS+=(
  -e "TERM=${TERM:-xterm-256color}"
  -e "LANG=${LANG:-C.UTF-8}"
  -e "LC_ALL=${LC_ALL:-C.UTF-8}"
)

if [[ "$SAVE_CONFIG" -eq 1 ]]; then
  save_config
fi

start_gateway() {
  build_image
  local docker_net_args=()
  local dns_args=("${DNS_ARGS[@]}")

  if [[ "$NETWORK_HOST" -eq 1 ]]; then
    dns_args=()
    docker_net_args+=(--network host --add-host=host.docker.internal:127.0.0.1 --add-host=host.containers.internal:127.0.0.1)
  else
    docker_net_args+=(--add-host="host.docker.internal:$HOST_GATEWAY_TARGET" --add-host="host.containers.internal:$HOST_GATEWAY_TARGET")
  fi

  if container_is_running; then
    echo "Gateway container '$CONTAINER_NAME' is already running."
    return 0
  fi

  if container_exists; then
    if [[ "$BUILD" -eq 1 ]]; then
      docker rm -f "$CONTAINER_NAME" >/dev/null
    else
      docker start "$CONTAINER_NAME" >/dev/null
      echo "Gateway container '$CONTAINER_NAME' started."
      return 0
    fi
  fi

  docker run -d \
    --name "$CONTAINER_NAME" \
    --restart unless-stopped \
    "${docker_net_args[@]}" \
    "${dns_args[@]}" \
    "${ENV_ARGS[@]}" \
    -e HOME="$HOME_CONT" \
    -e HERMES_HOME="$HERMES_DIR_CONT" \
    -v "$HERMES_DIR_HOST:$HERMES_DIR_CONT" \
    -v "$CODEX_DIR_HOST:$CODEX_DIR_CONT" \
    -v "$HERMES_HISTORY_HOST:$HERMES_HISTORY_CONT" \
    -v "$HERMES_GATEWAY_TMP_DIR_HOST:/tmp" \
    -v "$PROJECT_DIR:$WORKDIR_CONT" \
    -w "$WORKDIR_CONT" \
    "$TARGET_IMAGE_NAME" \
    gateway >/dev/null

  echo "Gateway container '$CONTAINER_NAME' started."
}

case "$ACTION" in
  start)
    start_gateway
    ;;
  stop)
    if container_is_running; then
      docker stop "$CONTAINER_NAME" >/dev/null
      echo "Gateway container '$CONTAINER_NAME' stopped."
    else
      echo "Gateway container '$CONTAINER_NAME' is not running."
    fi
    ;;
  restart)
    if container_exists; then
      docker rm -f "$CONTAINER_NAME" >/dev/null
    fi
    start_gateway
    ;;
  status)
    if container_exists; then
      docker ps -a --filter "name=^${CONTAINER_NAME}$" --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
    else
      echo "Gateway container '$CONTAINER_NAME' does not exist."
    fi
    ;;
  logs)
    if container_exists; then
      exec docker logs -f "$CONTAINER_NAME"
    else
      echo "Gateway container '$CONTAINER_NAME' does not exist."
      exit 1
    fi
    ;;
  rm)
    if container_exists; then
      docker rm -f "$CONTAINER_NAME" >/dev/null
      echo "Gateway container '$CONTAINER_NAME' removed."
    else
      echo "Gateway container '$CONTAINER_NAME' does not exist."
    fi
    ;;
esac
