#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# claude-box — single-file runner for Claude Code CLI in Docker
# ------------------------------------------------------------

IMAGE_NAME="${CLAUDE_IMAGE:-claude-box:node24}"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
CLAUDE_DIR_HOST="${CLAUDE_DIR_HOST:-$HOME/.claude}"
CLAUDE_JSON_HOST="${CLAUDE_JSON_HOST:-$HOME/.claude.json}"

HOME_CONT="/home/node"
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
EXTRA_MOUNT_ARGS=()

usage() {
  cat <<'EOF'
Usage:
  ./claude-box.sh [--build] [--force-build] [--project <path>] [-e VAR[=value]]... [-d local|-d <ip>] -- [claude-args...]

Examples:
  ./claude-box.sh -- --help
  ./claude-box.sh --build -- chat
  ./claude-box.sh --project /path/to/project -- --model claude-3-opus
  ./claude-box.sh -e GITLAB_TOKEN=abc123 -e TEST_API_KEY=xyz -- --help

Options:
  --build         Build the image if it does not exist yet
  --force-build   Always rebuild the image (no cache)
  --project PATH  Project directory to mount (default: current directory)
  -e VAR[=value]   Pass environment variable to container (can be used multiple times)
  -d MODE|IP       DNS mode: 'local' uses host resolver, or pass an IP address

Display/Session passthrough:
  If an X11 or Wayland session is detected, claude-box automatically forwards
  the needed env vars and sockets so Claude can access desktop image input.
EOF
}

# ------------------ argument parsing ------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --build)
      BUILD=1; shift ;;
    --force-build)
      FORCE_BUILD=1; BUILD=1; shift ;;
    --project)
      PROJECT_DIR="$2"; shift 2 ;;
    -e)
      if [[ -n "${2:-}" ]]; then
        EXTRA_ENV_ARGS+=(-e "$2")
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
        else
          DNS_IP="$2"
        fi
        shift 2
      else
        echo "Error: -d requires an argument (local or IP)" >&2
        exit 1
      fi
      ;;
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
mkdir -p "$CLAUDE_DIR_HOST"

# ------------------ inline Dockerfile ------------------
DOCKERFILE=$(cat <<'EOF'
FROM node:24-bookworm

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates git openssh-client tini curl wget \
    jq tree less vim \
  && rm -rf /var/lib/apt/lists/*

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

RUN npm install -g @anthropic-ai/claude-code

ENV HOME=/home/node
WORKDIR /workspace
USER node

ENTRYPOINT ["/usr/bin/tini","--","claude"]
EOF
)

# ------------------ build image ------------------
image_exists() {
  docker image inspect "$IMAGE_NAME" >/dev/null 2>&1
}

if [[ "$BUILD" -eq 1 || "$FORCE_BUILD" -eq 1 ]] || ! image_exists; then
  echo "▶ Building Docker image: $IMAGE_NAME"
  if [[ "$FORCE_BUILD" -eq 1 ]]; then
    docker build --no-cache -t "$IMAGE_NAME" - <<EOF
$DOCKERFILE
EOF
  else
    docker build -t "$IMAGE_NAME" - <<EOF
$DOCKERFILE
EOF
  fi
fi

# ------------------ env passthrough ------------------
ENV_ARGS=()
for var in ANTHROPIC_API_KEY ANTHROPIC_BASE_URL HTTP_PROXY HTTPS_PROXY NO_PROXY; do
  [[ -n "${!var:-}" ]] && ENV_ARGS+=(-e "$var=${!var}")
done

# Add extra environment variables from -e flags
ENV_ARGS+=("${EXTRA_ENV_ARGS[@]}")

# ------------------ DNS override ------------------
DNS_ARGS=()
if [[ "$DNS_MODE" == "local" ]]; then
  if [[ -f /etc/resolv.conf ]]; then
    LOCAL_DNS=$(grep -m1 '^nameserver' /etc/resolv.conf | awk '{print $2}')
    if [[ -n "$LOCAL_DNS" ]]; then
      DNS_ARGS+=(--dns "$LOCAL_DNS")
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

# ------------------ extra mounts ------------------
if [[ -f "$CLAUDE_JSON_HOST" ]]; then
  EXTRA_MOUNT_ARGS+=(-v "$CLAUDE_JSON_HOST:$CLAUDE_JSON_CONT:ro")
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
DOCKER_ARGS=(run --rm --add-host=host.docker.internal:host-gateway)
[[ -t 0 ]] && [[ -t 1 ]] && DOCKER_ARGS+=(-it)

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
  -v "$PROJECT_DIR:$WORKDIR_CONT" \
  -w "$WORKDIR_CONT" \
  "$IMAGE_NAME" \
  "$@"
