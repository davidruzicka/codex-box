#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# kimi-box — single-file runner for Kimi Code CLI in Docker
# ------------------------------------------------------------

BASE_IMAGE_NAME="${KIMI_IMAGE:-kimi-box:python313}"
PROJECT_DIR="${KIMI_PROJECT_DIR:-$PWD}"
KIMI_DIR_HOST="${KIMI_DIR_HOST:-$HOME/.kimi}"
KIMI_BOX_CONFIG_DIR="${KIMI_BOX_CONFIG_DIR:-$HOME/.kimi-box}"
KIMI_BOX_CONFIG_FILE="$KIMI_BOX_CONFIG_DIR/config"
KIMI_TMP_DIR_HOST="${KIMI_TMP_DIR_HOST:-$KIMI_BOX_CONFIG_DIR/tmp}"

HOME_CONT="/home/kimi"
KIMI_DIR_CONT="${HOME_CONT}/.kimi"
WORKDIR_CONT="/workspace"

BUILD=0
FORCE_BUILD=0
EXTRA_ENV_ARGS=()
SESSION_ENV_ARGS=()
SESSION_DOCKER_ARGS=()
DNS_MODE=""
DNS_IP=""
DNS_ARGS=()
BUILD_NETWORK_ARGS=()
SAVE_CONFIG=0
LATEST_KIMI_VERSION=""
IMAGE_REPO=""
IMAGE_TAG_BASE=""
TARGET_IMAGE_NAME="$BASE_IMAGE_NAME"
USE_VERSIONED_TAG=1
AUTO_UPDATE=1

usage() {
  cat <<'EOF'
Usage:
  ./kimi-box.sh [--build] [--force-build] [--no-auto-update] [--project <path>] [-e VAR[=value]]... [-d local|-d <ip>] [-s] -- [kimi-args...]

Examples:
  ./kimi-box.sh -- --help
  ./kimi-box.sh --build -- --continue
  ./kimi-box.sh --project /path/to/project -- --thinking
  ./kimi-box.sh -e KIMI_API_KEY=sk-xxx -- --help

Options:
  --build         Build the image if it does not exist yet
  --force-build   Always rebuild the image (no cache)
  --no-auto-update Disable Kimi CLI version check and auto rebuild to latest version
  --project PATH  Project directory to mount (default: current directory)
  -e VAR[=value]   Pass environment variable to container (can be used multiple times)
  -d MODE|IP       DNS mode: 'local' uses host resolver, or pass an IP address
  -s               Save -d and -e settings to ~/.kimi-box/config

Auto-update:
  By default, kimi-box checks the latest kimi-cli version from PyPI.
  It builds/runs a versioned image tag (<base-tag>-kimi-<version>) and
  rebuilds automatically when a newer Kimi CLI version is available.
  After a successful rebuild, old kimi version tags for the same base tag
  are removed.

Display/Session passthrough:
  If an X11 or Wayland session is detected, kimi-box automatically forwards
  the needed env vars and sockets so Kimi can access desktop image input.

Config directory (~/.kimi/):
  The host's ~/.kimi directory is mounted into the container. It contains:
    config.toml       — providers, models, services configuration
    kimi.json         — runtime metadata
    mcp.json          — MCP server configuration
    credentials/      — OAuth tokens
    sessions/         — conversation history
    plans/            — plan mode files
    user-history/     — input history
    logs/             — runtime logs
EOF
}

parse_image_reference() {
  local ref="$1"
  local last_segment="${ref##*/}"

  if [[ "$last_segment" == *:* ]]; then
    IMAGE_REPO="${ref%:*}"
    IMAGE_TAG_BASE="${ref##*:}"
  else
    IMAGE_REPO="$ref"
    IMAGE_TAG_BASE="latest"
  fi
}

get_latest_kimi_version() {
  docker run --rm "${DNS_ARGS[@]}" --entrypoint pip python:3.13-slim \
    index versions kimi-cli 2>/dev/null \
    | grep -oP 'Available versions: \K[0-9][0-9.]*' \
    | head -n1 | tr -d $'\r'
}

cleanup_old_kimi_images() {
  local prefix="$IMAGE_REPO:${IMAGE_TAG_BASE}-kimi-"
  local image_ref

  while IFS= read -r image_ref; do
    [[ -z "$image_ref" ]] && continue
    [[ "$image_ref" == "$TARGET_IMAGE_NAME" ]] && continue
    [[ "$image_ref" == "$prefix"* ]] || continue
    docker image rm "$image_ref" >/dev/null 2>&1 || true
  done < <(docker image ls --format '{{.Repository}}:{{.Tag}}' "$IMAGE_REPO")
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
  [[ -f "$KIMI_BOX_CONFIG_FILE" ]] || return 0

  while IFS= read -r line; do
    line="${line%%$'\r'}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    case "$line" in
      DNS_MODE=*) DNS_MODE="${line#DNS_MODE=}" ;;
      DNS_IP=*) DNS_IP="${line#DNS_IP=}" ;;
      ENV\ *) set_env_arg "${line#ENV }" ;;
    esac
  done < "$KIMI_BOX_CONFIG_FILE"
}

save_config() {
  mkdir -p "$KIMI_BOX_CONFIG_DIR"
  {
    echo "# kimi-box config"
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
  } > "$KIMI_BOX_CONFIG_FILE"
}

load_config
parse_image_reference "$BASE_IMAGE_NAME"

if [[ "$IMAGE_TAG_BASE" == *"-kimi-"* ]]; then
  USE_VERSIONED_TAG=0
fi

# ------------------ argument parsing ------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --build)
      BUILD=1; shift ;;
    --force-build)
      FORCE_BUILD=1; BUILD=1; shift ;;
    --no-auto-update)
      AUTO_UPDATE=0; shift ;;
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
mkdir -p "$KIMI_DIR_HOST"
mkdir -p "$KIMI_TMP_DIR_HOST"

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
FROM python:3.13-slim-bookworm

ARG KIMI_VERSION=latest

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates git openssh-client tini curl wget \
  gh \
    jq tree less vim \
    locales ncurses-term \
    ripgrep \
    fd-find \
    bat \
  && ln -sf /usr/bin/fdfind /usr/local/bin/fd \
  && ln -sf /usr/bin/batcat /usr/local/bin/bat \
  && rm -rf /var/lib/apt/lists/*

# Install uv and kimi-cli
RUN pip install --no-cache-dir uv \
  && mkdir -p /opt/uv-tools \
  && if [ "$KIMI_VERSION" = "latest" ]; then \
       UV_TOOL_DIR=/opt/uv-tools UV_TOOL_BIN_DIR=/usr/local/bin uv tool install --python 3.13 kimi-cli; \
     else \
       UV_TOOL_DIR=/opt/uv-tools UV_TOOL_BIN_DIR=/usr/local/bin uv tool install --python 3.13 "kimi-cli==$KIMI_VERSION"; \
     fi

# Create non-root user matching the common host UID/GID assumption.
RUN groupadd -g 1000 kimi && useradd -u 1000 -g 1000 -m -d /home/kimi kimi

ENV HOME=/home/kimi
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8
ENV PATH="/usr/local/bin:$PATH"
WORKDIR /workspace
USER kimi

ENTRYPOINT ["/usr/bin/tini","--","kimi"]
EOF
)

# ------------------ build image ------------------
image_exists() {
  docker image inspect "$1" >/dev/null 2>&1
}

if [[ "$AUTO_UPDATE" -eq 1 && "$USE_VERSIONED_TAG" -eq 1 ]]; then
  LATEST_KIMI_VERSION="$(get_latest_kimi_version || true)"
  if [[ -n "$LATEST_KIMI_VERSION" ]]; then
    TARGET_IMAGE_NAME="$IMAGE_REPO:${IMAGE_TAG_BASE}-kimi-$LATEST_KIMI_VERSION"
  else
    echo "Warning: could not determine latest kimi-cli version, continuing with base image tag: $BASE_IMAGE_NAME" >&2
    TARGET_IMAGE_NAME="$BASE_IMAGE_NAME"
  fi
else
  TARGET_IMAGE_NAME="$BASE_IMAGE_NAME"
fi

if [[ "$BUILD" -eq 1 || "$FORCE_BUILD" -eq 1 ]] || ! image_exists "$TARGET_IMAGE_NAME"; then
  echo "▶ Building Docker image: $TARGET_IMAGE_NAME"
  if [[ "$FORCE_BUILD" -eq 1 ]]; then
    if [[ -n "$LATEST_KIMI_VERSION" ]]; then
      docker build --no-cache "${BUILD_NETWORK_ARGS[@]}" --build-arg "KIMI_VERSION=$LATEST_KIMI_VERSION" -t "$TARGET_IMAGE_NAME" - <<EOF
$DOCKERFILE
EOF
    else
      docker build --no-cache "${BUILD_NETWORK_ARGS[@]}" -t "$TARGET_IMAGE_NAME" - <<EOF
$DOCKERFILE
EOF
    fi
  else
    if [[ -n "$LATEST_KIMI_VERSION" ]]; then
      docker build "${BUILD_NETWORK_ARGS[@]}" --build-arg "KIMI_VERSION=$LATEST_KIMI_VERSION" -t "$TARGET_IMAGE_NAME" - <<EOF
$DOCKERFILE
EOF
    else
      docker build "${BUILD_NETWORK_ARGS[@]}" -t "$TARGET_IMAGE_NAME" - <<EOF
$DOCKERFILE
EOF
    fi
  fi

  if [[ -n "$LATEST_KIMI_VERSION" ]]; then
    cleanup_old_kimi_images
  fi
fi

# ------------------ env passthrough ------------------
ENV_ARGS=()
for var in KIMI_API_KEY KIMI_BASE_URL KIMI_MODEL_NAME KIMI_SHARE_DIR HTTP_PROXY HTTPS_PROXY NO_PROXY \
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

# Disable auto-update inside the container
ENV_ARGS+=(-e "KIMI_CLI_NO_AUTO_UPDATE=1")

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
# Use -it only if TTY is available
DOCKER_ARGS=(run --rm --add-host=host.docker.internal:host-gateway)
[[ -t 0 ]] && [[ -t 1 ]] && DOCKER_ARGS+=(-it)

if [[ "$SAVE_CONFIG" -eq 1 ]]; then
  save_config
fi

exec docker "${DOCKER_ARGS[@]}" \
  "${DNS_ARGS[@]}" \
  "${ENV_ARGS[@]}" \
  "${SESSION_ENV_ARGS[@]}" \
  "${SESSION_DOCKER_ARGS[@]}" \
  -e HOME="$HOME_CONT" \
  -v "$KIMI_DIR_HOST:$KIMI_DIR_CONT" \
  -v "$KIMI_TMP_DIR_HOST:/tmp" \
  -v "$PROJECT_DIR:$WORKDIR_CONT" \
  -w "$WORKDIR_CONT" \
  "$TARGET_IMAGE_NAME" \
  "$@"
