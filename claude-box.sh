#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# claude-box — single-file runner for Claude Code CLI in Docker
# ------------------------------------------------------------

BASE_IMAGE_NAME="${CLAUDE_IMAGE:-claude-box:node24}"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
CLAUDE_DIR_HOST="${CLAUDE_DIR_HOST:-$HOME/.claude}"
CLAUDE_JSON_HOST="${CLAUDE_JSON_HOST:-$HOME/.claude.json}"
CLAUDE_BOX_CONFIG_DIR="${CLAUDE_BOX_CONFIG_DIR:-$HOME/.claude-box}"
CLAUDE_BOX_CONFIG_FILE="$CLAUDE_BOX_CONFIG_DIR/config"
CLAUDE_TMP_DIR_HOST="${CLAUDE_TMP_DIR_HOST:-$CLAUDE_BOX_CONFIG_DIR/tmp}"

HOME_CONT="/home/node"
CLAUDE_DIR_CONT="${HOME_CONT}/.claude"
CLAUDE_JSON_CONT="${HOME_CONT}/.claude.json"
GSC_CREDENTIALS_CONT="${HOME_CONT}/.gsc-credentials.json"
GA4_CREDENTIALS_CONT="${HOME_CONT}/.ga4-service-account.json"
GADS_CREDENTIALS_CONT="${HOME_CONT}/google-ads.yaml"
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
EXTRA_MOUNT_ARGS=()
SAVE_CONFIG=0
LATEST_CLAUDE_VERSION=""
IMAGE_REPO=""
IMAGE_TAG_BASE=""
TARGET_IMAGE_NAME="$BASE_IMAGE_NAME"
USE_VERSIONED_TAG=1
AUTO_UPDATE=1
NETWORK_HOST=0

usage() {
  cat <<'EOF'
Usage:
  ./claude-box.sh [--build] [--force-build] [--no-auto-update] [--network-host] [--project <path>] [-e VAR[=value]]... [-d local|-d <ip>] [-s] -- [claude-args...]

Examples:
  ./claude-box.sh -- --help
  ./claude-box.sh --build -- chat
  ./claude-box.sh --project /path/to/project -- --model claude-3-opus
  ./claude-box.sh -e GITLAB_TOKEN=abc123 -e TEST_API_KEY=xyz -- --help

Options:
  --build         Build the image if it does not exist yet
  --force-build   Always rebuild the image (no cache)
  --no-auto-update Disable Claude version check and auto rebuild to latest version
  --network-host  Use host networking (workaround when bridge cannot reach host services)
  --project PATH  Project directory to mount (default: current directory)
  -e VAR[=value]   Pass environment variable to container (can be used multiple times)
  -d MODE|IP       DNS mode: 'local' uses host resolver, or pass an IP address
  -s               Save -d and -e settings to ~/.claude-box/config

Auto-update:
  By default, claude-box checks the latest @anthropic-ai/claude-code version from npm.
  It builds/runs a versioned image tag (<base-tag>-claude-<version>) and
  rebuilds automatically when a newer Claude version is available.
  After a successful rebuild, old claude version tags for the same base tag
  are removed.

Display/Session passthrough:
  If an X11 or Wayland session is detected, claude-box automatically forwards
  the needed env vars and sockets so Claude can access desktop image input.
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
  [[ -f "$CLAUDE_BOX_CONFIG_FILE" ]] || return 0

  while IFS= read -r line; do
    line="${line%%$'\r'}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    case "$line" in
      DNS_MODE=*) DNS_MODE="${line#DNS_MODE=}" ;;
      DNS_IP=*) DNS_IP="${line#DNS_IP=}" ;;
      ENV\ *) set_env_arg "${line#ENV }" ;;
    esac
  done < "$CLAUDE_BOX_CONFIG_FILE"
}

save_config() {
  mkdir -p "$CLAUDE_BOX_CONFIG_DIR"
  {
    echo "# claude-box config"
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
  } > "$CLAUDE_BOX_CONFIG_FILE"
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

get_latest_claude_version() {
  docker run --rm "${DNS_ARGS[@]}" --entrypoint npm node:24-bookworm \
    view @anthropic-ai/claude-code version --silent 2>/dev/null | tr -d $'\r' | tail -n1
}

cleanup_old_claude_images() {
  local prefix="$IMAGE_REPO:${IMAGE_TAG_BASE}-claude-"
  local image_ref

  while IFS= read -r image_ref; do
    [[ -z "$image_ref" ]] && continue
    [[ "$image_ref" == "$TARGET_IMAGE_NAME" ]] && continue
    [[ "$image_ref" == "$prefix"* ]] || continue
    docker image rm "$image_ref" >/dev/null 2>&1 || true
  done < <(docker image ls --format '{{.Repository}}:{{.Tag}}' "$IMAGE_REPO")
}

parse_image_reference "$BASE_IMAGE_NAME"
load_config

if [[ "$IMAGE_TAG_BASE" == *"-claude-"* ]]; then
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
    --)
      shift; break ;;
    *)
      break ;;
  esac
done

# ------------------ sanity checks ------------------
[[ -d "$PROJECT_DIR" ]] || { echo "Error: project directory does not exist: $PROJECT_DIR" >&2; exit 1; }
mkdir -p "$CLAUDE_DIR_HOST" "$CLAUDE_DIR_HOST/commands"
mkdir -p "$CLAUDE_TMP_DIR_HOST"

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

HOST_GATEWAY_TARGET="${CLAUDE_HOST_GATEWAY_TARGET:-host-gateway}"

# ------------------ inline Dockerfile ------------------
DOCKERFILE=$(cat <<'EOF'
FROM node:24-bookworm

ARG CLAUDE_VERSION=latest

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates git openssh-client tini curl wget \
    gh \
    hunspell hunspell-cs hunspell-en-us \
    jq tree less vim nano locales ncurses-term python3-yaml python3-pytest \
    fzf zsh unzip procps gnupg2 man-db \
    nmap iputils-ping bind9-dnsutils netcat-openbsd \
    && rm -rf /var/lib/apt/lists/*

ARG GIT_DELTA_VERSION=0.18.2
RUN ARCH=$(dpkg --print-architecture) \
  && wget "https://github.com/dandavison/delta/releases/download/${GIT_DELTA_VERSION}/git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" \
  && dpkg -i "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" || apt-get install -f -y \
  && rm -f "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb"

# Install ripgrep (rg)
RUN curl -L https://github.com/BurntSushi/ripgrep/releases/download/14.1.1/ripgrep_14.1.1_amd64.deb -o /tmp/ripgrep.deb \
  && dpkg -i /tmp/ripgrep.deb || apt-get install -f -y \
  && rm /tmp/ripgrep.deb

# Install fd-find (fd)
RUN curl -L https://github.com/sharkdp/fd/releases/download/v9.0.0/fd_9.0.0_amd64.deb -o /tmp/fd.deb \
  && dpkg -i /tmp/fd.deb || apt-get install -f -y \
  && rm /tmp/fd.deb

# Install bat
RUN curl -L https://github.com/sharkdp/bat/releases/download/v0.24.0/bat_0.24.0_amd64.deb -o /tmp/bat.deb \
  && dpkg -i /tmp/bat.deb || apt-get install -f -y \
  && rm /tmp/bat.deb

RUN npm install -g "@anthropic-ai/claude-code@${CLAUDE_VERSION}"

# Install uv
RUN curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh

# Install Get Shit Done installer CLI (explicit use only)
RUN npm install -g get-shit-done-cc@latest

# Install lean-ctx and run setup for the container user home
RUN npm install -g lean-ctx-bin \
  && mkdir -p /home/node \
  && HOME=/home/node lean-ctx setup \
  && if [ -d /home/node/.lean-ctx ]; then chown -R node:node /home/node/.lean-ctx; fi

RUN cat > /usr/local/bin/claude-entrypoint <<'ENTRYPOINT' \
  && chmod +x /usr/local/bin/claude-entrypoint
#!/usr/bin/env bash
set -euo pipefail

if [[ ! -d "$HOME/.claude/commands/gsd" ]]; then
  if [[ -w "$HOME/.claude" || ( ! -e "$HOME/.claude" && -w "$HOME" ) ]]; then
    if ! get-shit-done-cc --claude --global >/tmp/gsd-bootstrap.log 2>&1; then
      echo "Warning: GSD bootstrap failed for Claude; continuing without GSD setup." >&2
      cat /tmp/gsd-bootstrap.log >&2
    fi
  fi
fi

exec claude "$@"
ENTRYPOINT

# Install Quint Code / Haft when upstream installer works.
RUN if ! curl -fsSL https://raw.githubusercontent.com/m0n0x41d/quint-code/main/install.sh | bash; then \
      echo "Warning: quint-code/haft installer failed; continuing without Haft preinstall." >&2; \
    fi

ENV HOME=/home/node
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8
WORKDIR /workspace
USER node

ENTRYPOINT ["/usr/bin/tini","--","/usr/local/bin/claude-entrypoint"]
EOF
)

# ------------------ build image ------------------
image_exists() {
  docker image inspect "$1" >/dev/null 2>&1
}

if [[ "$AUTO_UPDATE" -eq 1 && "$USE_VERSIONED_TAG" -eq 1 ]]; then
  LATEST_CLAUDE_VERSION="$(get_latest_claude_version || true)"
  if [[ -n "$LATEST_CLAUDE_VERSION" ]]; then
    TARGET_IMAGE_NAME="$IMAGE_REPO:${IMAGE_TAG_BASE}-claude-$LATEST_CLAUDE_VERSION"
  else
    echo "Warning: could not determine latest @anthropic-ai/claude-code version, continuing with base image tag: $BASE_IMAGE_NAME" >&2
    TARGET_IMAGE_NAME="$BASE_IMAGE_NAME"
  fi
else
  TARGET_IMAGE_NAME="$BASE_IMAGE_NAME"
fi

if [[ "$BUILD" -eq 1 || "$FORCE_BUILD" -eq 1 ]] || ! image_exists "$TARGET_IMAGE_NAME"; then
  echo "▶ Building Docker image: $TARGET_IMAGE_NAME"
  if [[ "$FORCE_BUILD" -eq 1 ]]; then
    if [[ -n "$LATEST_CLAUDE_VERSION" ]]; then
      docker build --no-cache "${BUILD_NETWORK_ARGS[@]}" --build-arg "CLAUDE_VERSION=$LATEST_CLAUDE_VERSION" -t "$TARGET_IMAGE_NAME" - <<EOF
$DOCKERFILE
EOF
    else
      docker build --no-cache "${BUILD_NETWORK_ARGS[@]}" -t "$TARGET_IMAGE_NAME" - <<EOF
$DOCKERFILE
EOF
    fi
  else
    if [[ -n "$LATEST_CLAUDE_VERSION" ]]; then
      docker build "${BUILD_NETWORK_ARGS[@]}" --build-arg "CLAUDE_VERSION=$LATEST_CLAUDE_VERSION" -t "$TARGET_IMAGE_NAME" - <<EOF
$DOCKERFILE
EOF
    else
      docker build "${BUILD_NETWORK_ARGS[@]}" -t "$TARGET_IMAGE_NAME" - <<EOF
$DOCKERFILE
EOF
    fi
  fi

  if [[ -n "$LATEST_CLAUDE_VERSION" ]]; then
    cleanup_old_claude_images
  fi
fi

# ------------------ env passthrough ------------------
ENV_ARGS=()
for var in ANTHROPIC_API_KEY ANTHROPIC_BASE_URL HTTP_PROXY HTTPS_PROXY NO_PROXY \
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

# ------------------ extra mounts ------------------
if [[ -f "$CLAUDE_JSON_HOST" ]]; then
  EXTRA_MOUNT_ARGS+=(-v "$CLAUDE_JSON_HOST:$CLAUDE_JSON_CONT:rw")
fi

if [[ -f "${GSC_CREDENTIALS_PATH:-}" ]]; then
  EXTRA_MOUNT_ARGS+=(-v "$GSC_CREDENTIALS_PATH:$GSC_CREDENTIALS_CONT:ro")
  SESSION_ENV_ARGS+=(-e "GSC_CREDENTIALS_PATH=$GSC_CREDENTIALS_CONT")
fi

if [[ -f "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]]; then
  EXTRA_MOUNT_ARGS+=(-v "$GOOGLE_APPLICATION_CREDENTIALS:$GA4_CREDENTIALS_CONT:ro")
  SESSION_ENV_ARGS+=(-e "GOOGLE_APPLICATION_CREDENTIALS=$GA4_CREDENTIALS_CONT")
fi

if [[ -f "${GOOGLE_ADS_CREDENTIALS:-}" ]]; then
  EXTRA_MOUNT_ARGS+=(-v "$GOOGLE_ADS_CREDENTIALS:$GADS_CREDENTIALS_CONT:ro")
  SESSION_ENV_ARGS+=(-e "GOOGLE_ADS_CREDENTIALS=$GADS_CREDENTIALS_CONT")
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
# Default to interactive chat when no Claude args are provided.
if [[ $# -eq 0 ]]; then
  set -- chat
fi

# Use -it only if TTY is available.
if [[ "$NETWORK_HOST" -eq 1 ]]; then
  DNS_ARGS=()
  DOCKER_ARGS=(run --rm --network host --add-host=host.docker.internal:127.0.0.1 --add-host=host.containers.internal:127.0.0.1)
else
  DOCKER_ARGS=(run --rm --add-host="host.docker.internal:$HOST_GATEWAY_TARGET" --add-host="host.containers.internal:$HOST_GATEWAY_TARGET")
fi
[[ -t 0 ]] && [[ -t 1 ]] && DOCKER_ARGS+=(-it)

if [[ "$SAVE_CONFIG" -eq 1 ]]; then
  save_config
fi

# Claude interactive modes require a TTY. Without it, the process can appear frozen.
if [[ ! -t 0 || ! -t 1 ]]; then
  if [[ "${1:-}" == "chat" ]]; then
    echo "Error: Claude chat mode requires an interactive terminal (TTY)." >&2
    echo "Run from a terminal, or pass a non-interactive command (e.g. ./claude-box.sh -- --help)." >&2
    exit 1
  fi
fi

exec docker "${DOCKER_ARGS[@]}" \
  "${DNS_ARGS[@]}" \
  "${ENV_ARGS[@]}" \
  "${SESSION_ENV_ARGS[@]}" \
  "${SESSION_DOCKER_ARGS[@]}" \
  -e HOME="$HOME_CONT" \
  "${EXTRA_MOUNT_ARGS[@]}" \
  -v "$CLAUDE_DIR_HOST:$CLAUDE_DIR_CONT" \
  -v "$CLAUDE_TMP_DIR_HOST:/tmp" \
  -v "$PROJECT_DIR:$WORKDIR_CONT" \
  -w "$WORKDIR_CONT" \
  "$TARGET_IMAGE_NAME" \
  "$@"
