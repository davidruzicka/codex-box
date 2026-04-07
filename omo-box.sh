#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# omo-box — single-file runner for OpenCode + Oh My OpenAgent in Docker
# ------------------------------------------------------------

BASE_IMAGE_NAME="${OMO_IMAGE:-omo-box:node24}"
PROJECT_DIR="${OMO_PROJECT_DIR:-$PWD}"
OMO_CONFIG_DIR_HOST="${OMO_CONFIG_DIR_HOST:-$HOME/.config/opencode}"
OMO_DATA_DIR_HOST="${OMO_DATA_DIR_HOST:-$HOME/.local/share/opencode}"
CLAUDE_DIR_HOST="${CLAUDE_DIR_HOST:-$HOME/.claude}"
CLAUDE_JSON_HOST="${CLAUDE_JSON_HOST:-$HOME/.claude.json}"
OMO_BOX_CONFIG_DIR="${OMO_BOX_CONFIG_DIR:-$HOME/.omo-box}"
OMO_BOX_CONFIG_FILE="$OMO_BOX_CONFIG_DIR/config"
OMO_TMP_DIR_HOST="${OMO_TMP_DIR_HOST:-$OMO_BOX_CONFIG_DIR/tmp}"

HOME_CONT="/home/node"
OMO_CONFIG_DIR_CONT="${HOME_CONT}/.config/opencode"
OMO_DATA_DIR_CONT="${HOME_CONT}/.local/share/opencode"
CLAUDE_DIR_CONT="${HOME_CONT}/.claude"
CLAUDE_JSON_CONT="${HOME_CONT}/.claude.json"
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
LATEST_OMO_VERSION=""
IMAGE_REPO=""
IMAGE_TAG_BASE=""
TARGET_IMAGE_NAME="$BASE_IMAGE_NAME"
USE_VERSIONED_TAG=1
AUTO_UPDATE=1

usage() {
  cat <<'EOF'
Usage:
  ./omo-box.sh [--build] [--force-build] [--no-auto-update] [--project <path>] [-e VAR[=value]]... [-d local|-d <ip>] [-s] -- [opencode-args...]

Examples:
  ./omo-box.sh -- --help
  ./omo-box.sh --build
  ./omo-box.sh --project /path/to/project -- run "explain this project"
  ./omo-box.sh -e ANTHROPIC_API_KEY=sk-ant-xxx -- --help

Options:
  --build         Build the image if it does not exist yet
  --force-build   Always rebuild the image (no cache)
  --no-auto-update Disable oh-my-opencode version check and auto rebuild
  --project PATH  Project directory to mount (default: current directory)
  -e VAR[=value]   Pass environment variable to container (can be used multiple times)
  -d MODE|IP       DNS mode: 'local' uses host resolver, or pass an IP address
  -s               Save -d and -e settings to ~/.omo-box/config

Auto-update:
  By default, omo-box checks the latest oh-my-opencode version from npm.
  It builds/runs a versioned image tag (<base-tag>-omo-<version>) and
  rebuilds automatically when a newer version is available.
  After a successful rebuild, old omo version tags for the same base tag
  are removed.

Privacy defaults:
  Unless OPENCODE_CONFIG or OPENCODE_CONFIG_CONTENT is provided,
  omo-box applies defaults:
    share=disabled
    experimental.openTelemetry=false

Display/Session passthrough:
  If an X11 or Wayland session is detected, omo-box automatically forwards
  the needed env vars and sockets so OpenCode can access desktop image input.

Config directory (~/.config/opencode/):
  The host's ~/.config/opencode directory is mounted into the container:
    opencode.json       — main OpenCode config (providers, models, plugins)
    oh-my-opencode.json — oh-my-opencode plugin config (agents, hooks)
    tui.json            — TUI settings (theme, keybinds)
    agents/             — custom agent definitions
    commands/           — custom commands
    plugins/            — local plugins
    skills/             — agent skills

Auth storage (~/.local/share/opencode/):
  The host's ~/.local/share/opencode directory is also mounted so `opencode`
  can persist credentials created by `/connect` and OAuth/device login flows
  (for example `auth.json`).

Claude config passthrough (read-only):
  If present on host, `~/.claude` and `~/.claude.json` are mounted read-only
  so OpenCode/OMO can reuse existing Claude Code configuration.

  Project config (.opencode/) is inside the mounted project directory.
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

get_latest_omo_version() {
  docker run --rm "${DNS_ARGS[@]}" --entrypoint npm node:24-bookworm \
    view oh-my-opencode version --silent 2>/dev/null | tr -d $'\r' | tail -n1
}

cleanup_old_omo_images() {
  local prefix="$IMAGE_REPO:${IMAGE_TAG_BASE}-omo-"
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
  [[ -f "$OMO_BOX_CONFIG_FILE" ]] || return 0

  while IFS= read -r line; do
    line="${line%%$'\r'}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    case "$line" in
      DNS_MODE=*) DNS_MODE="${line#DNS_MODE=}" ;;
      DNS_IP=*) DNS_IP="${line#DNS_IP=}" ;;
      ENV\ *) set_env_arg "${line#ENV }" ;;
    esac
  done < "$OMO_BOX_CONFIG_FILE"
}

save_config() {
  mkdir -p "$OMO_BOX_CONFIG_DIR"
  {
    echo "# omo-box config"
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
  } > "$OMO_BOX_CONFIG_FILE"
}

load_config
parse_image_reference "$BASE_IMAGE_NAME"

if [[ "$IMAGE_TAG_BASE" == *"-omo-"* ]]; then
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
mkdir -p "$OMO_CONFIG_DIR_HOST"
mkdir -p "$OMO_DATA_DIR_HOST"
mkdir -p "$OMO_TMP_DIR_HOST"

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
FROM node:24-bookworm

ARG OMO_VERSION=latest

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates git openssh-client tini curl wget \
  gh \
    hunspell hunspell-cs hunspell-en-us \
    jq tree less vim \
    locales ncurses-term \
    ripgrep \
    fd-find \
    bat \
    tmux \
    python3-yaml python3-pytest \
  && ln -sf /usr/bin/fdfind /usr/local/bin/fd \
  && ln -sf /usr/bin/batcat /usr/local/bin/bat \
  && rm -rf /var/lib/apt/lists/*

RUN npm install -g opencode-ai
RUN if [ "$OMO_VERSION" = "latest" ]; then \
      npm install -g oh-my-opencode; \
    else \
      npm install -g "oh-my-opencode@${OMO_VERSION}"; \
    fi

RUN mkdir -p /home/node/.local/state /home/node/.local/share/opencode \
  && chown -R node:node /home/node/.local

ENV HOME=/home/node
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8
ENV XDG_STATE_HOME=/home/node/.local/state
WORKDIR /workspace
USER node

ENTRYPOINT ["/usr/bin/tini","--","opencode"]
EOF
)

# ------------------ build image ------------------
image_exists() {
  docker image inspect "$1" >/dev/null 2>&1
}

if [[ "$AUTO_UPDATE" -eq 1 && "$USE_VERSIONED_TAG" -eq 1 ]]; then
  LATEST_OMO_VERSION="$(get_latest_omo_version || true)"
  if [[ -n "$LATEST_OMO_VERSION" ]]; then
    TARGET_IMAGE_NAME="$IMAGE_REPO:${IMAGE_TAG_BASE}-omo-$LATEST_OMO_VERSION"
  else
    echo "Warning: could not determine latest oh-my-opencode version, continuing with base image tag: $BASE_IMAGE_NAME" >&2
    TARGET_IMAGE_NAME="$BASE_IMAGE_NAME"
  fi
else
  TARGET_IMAGE_NAME="$BASE_IMAGE_NAME"
fi

if [[ "$BUILD" -eq 1 || "$FORCE_BUILD" -eq 1 ]] || ! image_exists "$TARGET_IMAGE_NAME"; then
  echo "▶ Building Docker image: $TARGET_IMAGE_NAME"
  if [[ "$FORCE_BUILD" -eq 1 ]]; then
    if [[ -n "$LATEST_OMO_VERSION" ]]; then
      docker build --no-cache "${BUILD_NETWORK_ARGS[@]}" --build-arg "OMO_VERSION=$LATEST_OMO_VERSION" -t "$TARGET_IMAGE_NAME" - <<EOF
$DOCKERFILE
EOF
    else
      docker build --no-cache "${BUILD_NETWORK_ARGS[@]}" -t "$TARGET_IMAGE_NAME" - <<EOF
$DOCKERFILE
EOF
    fi
  else
    if [[ -n "$LATEST_OMO_VERSION" ]]; then
      docker build "${BUILD_NETWORK_ARGS[@]}" --build-arg "OMO_VERSION=$LATEST_OMO_VERSION" -t "$TARGET_IMAGE_NAME" - <<EOF
$DOCKERFILE
EOF
    else
      docker build "${BUILD_NETWORK_ARGS[@]}" -t "$TARGET_IMAGE_NAME" - <<EOF
$DOCKERFILE
EOF
    fi
  fi

  if [[ -n "$LATEST_OMO_VERSION" ]]; then
    cleanup_old_omo_images
  fi
fi

# ------------------ env passthrough ------------------
ENV_ARGS=()
for var in ANTHROPIC_API_KEY OPENAI_API_KEY GOOGLE_API_KEY GEMINI_API_KEY \
           OPENCODE_API_KEY OPENCODE_CONFIG OPENCODE_CONFIG_CONTENT \
           HTTP_PROXY HTTPS_PROXY NO_PROXY TERM COLORTERM TERM_PROGRAM \
           TERM_PROGRAM_VERSION LANG LC_ALL LC_CTYPE; do
  [[ -n "${!var:-}" ]] && ENV_ARGS+=(-e "$var=${!var}")
done

# Add extra environment variables from -e flags
ENV_ARGS+=("${EXTRA_ENV_ARGS[@]}")
ENV_ARGS+=(
  -e "TERM=${TERM:-xterm-256color}"
  -e "LANG=${LANG:-C.UTF-8}"
  -e "LC_ALL=${LC_ALL:-C.UTF-8}"
)

# Disable autoupdate inside the container (omo-box handles updates)
if [[ -z "${OPENCODE_CONFIG:-}" && -z "${OPENCODE_CONFIG_CONTENT:-}" ]]; then
  ENV_ARGS+=(-e "OPENCODE_CONFIG_CONTENT={\"autoupdate\":false,\"share\":\"disabled\",\"experimental\":{\"openTelemetry\":false}}")
fi

# ------------------ optional Claude config passthrough ------------------
CLAUDE_MOUNT_ARGS=()
if [[ -d "$CLAUDE_DIR_HOST" ]]; then
  CLAUDE_MOUNT_ARGS+=(-v "$CLAUDE_DIR_HOST:$CLAUDE_DIR_CONT:ro")
fi
if [[ -f "$CLAUDE_JSON_HOST" ]]; then
  CLAUDE_MOUNT_ARGS+=(-v "$CLAUDE_JSON_HOST:$CLAUDE_JSON_CONT:ro")
fi

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
  -v "$OMO_CONFIG_DIR_HOST:$OMO_CONFIG_DIR_CONT" \
  -v "$OMO_DATA_DIR_HOST:$OMO_DATA_DIR_CONT" \
  -v "$OMO_TMP_DIR_HOST:/tmp" \
  "${CLAUDE_MOUNT_ARGS[@]}" \
  -v "$PROJECT_DIR:$WORKDIR_CONT" \
  -w "$WORKDIR_CONT" \
  "$TARGET_IMAGE_NAME" \
  "$@"
