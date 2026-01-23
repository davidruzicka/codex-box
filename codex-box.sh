#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# codex-box — single-file runner for Codex CLI in Docker
# ------------------------------------------------------------

IMAGE_NAME="${CODEX_IMAGE:-codex-box:node24}"
PROJECT_DIR="${CODEX_PROJECT_DIR:-$PWD}"
CODEX_DIR_HOST="${CODEX_DIR_HOST:-$HOME/.codex}"

HOME_CONT="/home/node"
CODEX_DIR_CONT="${HOME_CONT}/.codex"
WORKDIR_CONT="/workspace"

BUILD=0
FORCE_BUILD=0

usage() {
  cat <<'EOF'
Usage:
  ./codex.sh [--build] [--force-build] [--project <path>] -- [codex-args...]

Examples:
  ./codex.sh -- --help
  ./codex.sh --build -- resume <SESSION_ID>
  ./codex.sh --project /path/to/project -- -m gpt-5-codex

Options:
  --build         Build the image if it does not exist yet
  --force-build   Always rebuild the image (no cache)
  --project PATH  Project directory to mount (default: current directory)
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
mkdir -p "$CODEX_DIR_HOST"

# ------------------ inline Dockerfile ------------------
read -r -d '' DOCKERFILE <<'EOF'
FROM node:24-bookworm

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates git openssh-client tini \
  && rm -rf /var/lib/apt/lists/*

RUN npm install -g @openai/codex

ENV HOME=/home/node
WORKDIR /workspace
USER node

ENTRYPOINT ["/usr/bin/tini","--","codex"]
EOF

# ------------------ build image ------------------
image_exists() {
  docker image inspect "$IMAGE_NAME" >/dev/null 2>&1
}

if [[ "$BUILD" -eq 1 || "$FORCE_BUILD" -eq 1 || ! image_exists ]]; then
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
for var in OPENAI_API_KEY OPENAI_BASE_URL HTTP_PROXY HTTPS_PROXY NO_PROXY; do
  [[ -n "${!var:-}" ]] && ENV_ARGS+=(-e "$var=${!var}")
done

# ------------------ run ------------------
exec docker run --rm -it \
  "${ENV_ARGS[@]}" \
  -e HOME="$HOME_CONT" \
  -v "$CODEX_DIR_HOST:$CODEX_DIR_CONT" \
  -v "$PROJECT_DIR:$WORKDIR_CONT" \
  -w "$WORKDIR_CONT" \
  "$IMAGE_NAME" \
  "$@"
