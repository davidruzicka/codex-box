# codex-box

A minimal, single-file Docker wrapper for running the OpenAI Codex CLI with
persistent sessions, safe UID handling, and a project-local workspace.

`codex-box` lets you run Codex in an isolated container while behaving like a
local CLI tool.

---

## Features

- **Single-file setup** – just download `codex-box.sh`
- **Persistent Codex sessions and config** via `~/.codex`
- **Runs as non-root** (uses the `node` user, UID 1000)
- **Project-local execution** (current directory mounted as workspace)
- **No Dockerfile needed** – image is built automatically
- **Compatible with MCP servers** (stdio or HTTP)

---

## Requirements

- Docker
- Bash
- An OpenAI API key

---

## Installation

Download the script and make it executable:

```bash
curl -LO https://raw.githubusercontent.com/davidruzicka/codex-box/main/codex-box.sh
chmod +x codex-box.sh
```

Optionally build the Docker image ahead of time:

```bash
./codex-box.sh --build -- --help
```

---

## Usage

Run Codex in the current project directory:

```bash
./codex-box.sh -- <codex arguments>
```

Examples:

```bash
./codex-box.sh -- --help
./codex-box.sh -- resume <SESSION_ID>
./codex-box.sh -- -m gpt-4-codex
```

### Using a Different Project Directory

```bash
./codex-box.sh --project /path/to/project -- <codex arguments>
```

---

## How It Works

- The script builds a Docker image based on `node:24`
- Codex is installed globally inside the image
- Your local `~/.codex` is mounted into the container at `/home/node/.codex`
- The project directory is mounted at `/workspace`
- Codex runs as the non-root `node` user

This ensures:
- persistent sessions and configuration
- no file permission issues
- reproducible execution

---

## Environment Variables

The following variables are passed through to the container if set:

- `OPENAI_API_KEY`
- `OPENAI_BASE_URL`
- `HTTP_PROXY`
- `HTTPS_PROXY`
- `NO_PROXY`

You can also override internal settings:

| Variable | Description | Default |
|--------|-------------|---------|
| `CODEX_IMAGE` | Docker image name | `codex-box:node24` |
| `CODEX_PROJECT_DIR` | Project directory to mount | current directory |
| `CODEX_DIR_HOST` | Host Codex config directory | `~/.codex` |

---

## MCP Support

Codex MCP servers are configured via `~/.codex/config.toml`.

Both stdio-based MCP servers and HTTP-based MCP servers are supported.
For HTTP MCP servers, it is recommended to run them in an isolated Docker
network and attach `codex-box` to that network.

---

## Security Notes

- Codex runs as a non-root user inside the container
- Only the project directory and `~/.codex` are mounted
- No additional network access is granted beyond Docker defaults

---

## Limitations

- Assumes host UID/GID is 1000 (default on most Linux systems)
- Requires Bash (not POSIX `sh`)
- Not intended as a multi-user or server setup

---

## License

[MIT](./LICENSE)
