# codex-box

A collection of minimal, single-file Docker wrappers for running AI coding
CLIs and agent harnesses with persistent config, isolated execution, and a
project-local workspace.

Available wrappers:

- `codex-box.sh` — OpenAI Codex CLI
- `claude-box.sh` — Claude Code
- `gemini-box.sh` — Gemini CLI
- `kimi-box.sh` — Kimi Code CLI
- `omo-box.sh` — OpenCode with Oh My OpenAgent
- `hermes-agent-box.sh` — Hermes Agent
- `hermes-agent-gateway-box.sh` — Hermes gateway runner

---

## Features

- **Single-file setup** – just download the wrapper you want
- **Persistent sessions and config** via tool-specific host directories
- **Runs in isolated containers** with tool-specific images
- **Runs as non-root** where supported by the wrapped CLI
- **Project-local execution** (current directory mounted as workspace)
- **No Dockerfile needed** – image is built automatically
- **Compatible with MCP servers** (stdio or HTTP)
- **Better terminal compatibility** via locale, terminfo, and terminal env passthrough

## Included Wrappers

| Script | Tool | Persistent host data |
|--------|------|----------------------|
| `codex-box.sh` | Codex CLI | `~/.codex` |
| `claude-box.sh` | Claude Code | `~/.claude`, `~/.claude.json` |
| `gemini-box.sh` | Gemini CLI | `~/.gemini` |
| `kimi-box.sh` | Kimi Code CLI | `~/.kimi` |
| `omo-box.sh` | OpenCode + Oh My OpenAgent | `~/.config/opencode`, `~/.local/share/opencode`, project `.opencode/` |
| `hermes-agent-box.sh` | Hermes Agent | `~/.hermes`, `~/.codex`, `~/.hermes_history` |
| `hermes-agent-gateway-box.sh` | Hermes gateway | `~/.hermes`, `~/.codex`, `~/.hermes_history` |

## Preinstalled helper tools

- `gh` (GitHub CLI) is preinstalled in all wrappers.
- `get-shit-done-cc` installer CLI is preinstalled in wrappers where it is supported:
	- `codex-box.sh`
	- `claude-box.sh`
	- `gemini-box.sh`
	- On first container run, wrappers attempt best-effort bootstrap into mounted runtime config directories (`~/.codex`, `~/.claude`, `~/.gemini`) when writable.
	- Wrappers auto-create required runtime directories on first run when they do not exist.
	- It is explicit-use only and does not affect normal wrapper behavior unless invoked.
	- Verification tip: use `which get-shit-done-cc` or `get-shit-done-cc --help`; avoid `--version` for passive checks because it may trigger installer flow.
- `quint-code` is preinstalled only in wrappers where it is supported:
	- `codex-box.sh`
	- `claude-box.sh`
	- `gemini-box.sh`
- `lean-ctx` is preinstalled and initialized (`lean-ctx setup`) in supported wrappers:
	- `codex-box.sh`
	- `claude-box.sh`
	- `gemini-box.sh`
	- `kimi-box.sh`
	- `omo-box.sh`
	- `hermes-agent-box.sh`
	- `hermes-agent-gateway-box.sh`
	- In `kimi-box.sh`, wrapper startup injects a `lean-ctx` MCP server via an ad-hoc `--mcp-config-file` (merged from `~/.kimi/mcp.json` when readable).

---

## Requirements

- Docker (or Podman with Docker compatible mode)
- Bash
- Authorization for the specific tool/provider you want to use

---
_Examples below are primarily for `codex-box.sh`, but the same flags are used by the other wrappers unless noted otherwise._
---

## Installation

Download the script and make it executable:

```bash
curl -LO https://raw.githubusercontent.com/davidruzicka/codex-box/main/codex-box.sh
chmod +x codex-box.sh
```

Or copy any of the other wrappers:

```bash
chmod +x claude-box.sh gemini-box.sh kimi-box.sh omo-box.sh hermes-agent-box.sh hermes-agent-gateway-box.sh
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
./codex-box.sh -d local -- --help
./codex-box.sh -d 192.168.31.1 -- --help
./codex-box.sh --network-host -- --help
./codex-box.sh -d local -e HTTP_PROXY=http://proxy:3128 -s -- --help
```

### Disable Auto-Update Check

By default, wrappers that support version tracking check the latest CLI version
from the upstream registry and may rebuild to a versioned image tag. Use
`--no-auto-update` to skip that check and use the base image tag only.

```bash
./codex-box.sh --no-auto-update -- --help
./claude-box.sh --no-auto-update -- --help
./gemini-box.sh --no-auto-update -- --help
./kimi-box.sh --no-auto-update -- --help
./omo-box.sh --no-auto-update -- --help
```

### Using a Different Project Directory

```bash
./codex-box.sh --project /path/to/project -- <codex arguments>
```

---

## How It Works

- The wrapper builds a Docker image on demand
- The target CLI or agent harness is installed inside the image
- Tool-specific config directories are mounted from the host
- The project directory is mounted at `/workspace`
- The wrapped CLI runs inside Docker but behaves like a local command

This ensures:
- persistent sessions and configuration
- no file permission issues
- reproducible execution

Temporary workspace behavior:
- Wrappers mount persistent host-backed `/tmp` into containers so crash/restart does not lose temporary files.
- Default host location is `~/.<wrapper>-box/tmp` (or corresponding Hermes gateway box dir).
- You can override per wrapper using `*_TMP_DIR_HOST` variables.
- Optional cleanup (delete files older than 7 days):
	`find ~/.codex-box/tmp ~/.claude-box/tmp ~/.gemini-box/tmp ~/.kimi-box/tmp ~/.omo-box/tmp ~/.hermes-agent-box/tmp ~/.hermes-agent-gateway-box/tmp -type f -mtime +7 -delete`

---

## Environment Variables

The following variables are passed through to the container if set:

- `OPENAI_API_KEY`
- `OPENAI_BASE_URL`
- `ANTHROPIC_API_KEY`
- `ANTHROPIC_BASE_URL`
- `GOOGLE_API_KEY`
- `GEMINI_API_KEY`
- `GOOGLE_APPLICATION_CREDENTIALS`
- `KIMI_API_KEY`
- `KIMI_BASE_URL`
- `KIMI_MODEL_NAME`
- `KIMI_SHARE_DIR`
- `OPENROUTER_API_KEY`
- `OPENCODE_API_KEY`
- `OPENCODE_CONFIG`
- `OPENCODE_CONFIG_CONTENT`
- `HTTP_PROXY`
- `HTTPS_PROXY`
- `NO_PROXY`
- `TERM`
- `COLORTERM`
- `TERM_PROGRAM`
- `TERM_PROGRAM_VERSION`
- `LANG`
- `LC_ALL`
- `LC_CTYPE`

If these variables are not set, the wrappers default to `TERM=xterm-256color`
and UTF-8 locale settings.

You can also override internal settings:

| Variable | Description | Default |
|--------|-------------|---------|
| `CODEX_IMAGE` | Docker image name | `codex-box:node24` |
| `CODEX_PROJECT_DIR` | Project directory to mount | current directory |
| `CODEX_DIR_HOST` | Host Codex config directory | `~/.codex` |
| `CODEX_TMP_DIR_HOST` | Host directory mounted to container `/tmp` | `~/.codex-box/tmp` |

Other wrappers use analogous temp-dir overrides:
- `CLAUDE_TMP_DIR_HOST`
- `GEMINI_TMP_DIR_HOST`
- `KIMI_TMP_DIR_HOST`
- `OMO_TMP_DIR_HOST`
- `HERMES_AGENT_TMP_DIR_HOST`
- `HERMES_GATEWAY_TMP_DIR_HOST`

## DNS Override

Use `-d local` to pass the host resolver into the container, or provide an IP
address to pass through as `--dns`.

## Host Networking Workaround

Use `--network-host` when the container cannot reach host services over bridge
networking (for example `host.docker.internal:3335` timing out on Linux).

Example:

```bash
./claude-box.sh --network-host -- chat
```

### `hermes-agent-gateway-box.sh`: bridge vs `--network-host`

- Prefer default bridge mode when container-to-container networking is needed.
- Use `--network-host` when the gateway must reach host-local services and
	bridge path to `host.docker.internal` is timing out/refused.

Examples:

```bash
./hermes-agent-gateway-box.sh --network-host start
./hermes-agent-gateway-box.sh --network-host restart
```

## Saved Defaults

Use `-s` to save the current `-d` and `-e` settings to `~/.codex-box/config`.
The file is loaded automatically on startup and CLI flags override saved values.

The same behavior is available in the other wrappers:

- `claude-box.sh` uses `~/.claude-box/config`
- `gemini-box.sh` uses `~/.gemini-box/config`
- `kimi-box.sh` uses `~/.kimi-box/config`
- `omo-box.sh` uses `~/.omo-box/config`
- `hermes-agent-box.sh` uses `~/.hermes-agent-box/config`
- `hermes-agent-gateway-box.sh` uses `~/.hermes-agent-gateway-box/config`

Examples:

```bash
./claude-box.sh -d local -e HTTP_PROXY=http://proxy:3128 -s -- --help
./gemini-box.sh -d 1.1.1.1 -e HTTP_PROXY=http://proxy:3128 -s -- --help
```

---

## MCP Support

Codex MCP servers are configured via `~/.codex/config.toml`.

Other wrappers use their native config locations, for example:

- Claude Code: `~/.claude` and `~/.claude.json`
- Kimi Code CLI: `~/.kimi/config.toml` and `~/.kimi/mcp.json`
- OpenCode / Oh My OpenAgent: `~/.config/opencode/opencode.json`, `~/.local/share/opencode/auth.json`, and project `.opencode/`
- Hermes Agent: `~/.hermes/`

Note: `omo-box.sh` does not reuse authentication from `~/.codex`, `~/.claude`,
`~/.claude.json`, or `~/.kimi`. OpenCode stores its own credentials under
`~/.local/share/opencode/`.

`omo-box.sh` additionally mounts Claude Code config as read-only (if present):

- `~/.claude` → `/home/node/.claude:ro`
- `~/.claude.json` → `/home/node/.claude.json:ro`

This lets OpenCode/OMO reuse Claude-related settings without duplicating config.

Privacy defaults in `omo-box.sh`:

- If neither `OPENCODE_CONFIG` nor `OPENCODE_CONFIG_CONTENT` is set,
	`omo-box.sh` injects default OpenCode config with:
	- `share: "disabled"`
	- `experimental.openTelemetry: false`
	- `autoupdate: false` (wrapper handles updates itself)
- If you pass `OPENCODE_CONFIG` or `OPENCODE_CONFIG_CONTENT`, your value is
	used as-is and wrapper defaults are not injected.

Both stdio-based MCP servers and HTTP-based MCP servers are supported.
For HTTP MCP servers, it is recommended to run them in an isolated Docker
network and attach `codex-box` to that network.

---

## Terminal Compatibility

Terminal apps inside Docker can show wrong colors or broken box-drawing /
Unicode characters when the container does not have matching locale or
terminfo data, or when terminal capability variables are not forwarded.

These wrappers address that by:

- installing `locales` and `ncurses-term` in the image
- setting `LANG=C.UTF-8` and `LC_ALL=C.UTF-8`
- forwarding terminal-related variables such as `TERM` and `COLORTERM`

This improves behavior for tools such as `vim`, `less`, `bat`, and interactive
agent CLIs running in the container.

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
