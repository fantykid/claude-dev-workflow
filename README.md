# Claude Dev Workflow

Reusable dual-role AI development workflow with Docker isolation.

Two agents with distinct responsibilities work in separate containers:

- **Bootstrap Claude Code** — Manages project infrastructure: asks what you want to build, generates the dev container Dockerfile, project config and agent guidance, and handles later adjustments.
- **Project agent** — Does the actual development with full autonomy inside an isolated, firewalled container. Choose **Claude Code** (`claude --dangerously-skip-permissions`, default) or **OpenAI Codex CLI** (`codex`) per project.

## Prerequisites

- Linux (tested on Ubuntu) with Docker (BuildKit, the default in current Docker releases)
- Git, `jq`, `curl`
- A Claude Code OAuth token — Bootstrap always runs Claude Code, even for Codex projects:
  ```bash
  claude setup-token            # on the host
  echo 'YOUR_TOKEN' > ~/.claude/.oauth-token && chmod 600 ~/.claude/.oauth-token
  ```
- Optional: the MCP Search Server container (`claude-mcp-search`, port 9100) for web search inside dev containers
- Optional: nvidia-container-toolkit for GPU projects

## Quick Start: Create a New Project

```bash
# 1. Clone this repo into your projects directory
cd ~/projects
git clone git@github.com:fantykid/claude-dev-workflow.git

# 2. Run init (creates the project as a sibling directory)
cd claude-dev-workflow
./init.sh my-app
```

`init.sh` builds or updates the Bootstrap image (it always tracks the latest Claude Code release) and launches you into the Bootstrap container.

```bash
# 3. Inside the Bootstrap container, run:
/init-project

# Describe your idea in natural language, e.g. "I want to build a blog website".
# Bootstrap decides the project type, ports, services and extra allowed domains,
# and asks whether the project agent should be Claude Code or Codex.
# Claude Code asks you to confirm writes to repo/.devcontainer/ and repo/.claude/ —
# glance at the Dockerfile before approving.

exit
```

```bash
# 4. Build the dev container image
cd ~/projects/my-app
./scripts/build.sh

# 5. Start the container (applies the firewall automatically)
./scripts/start.sh

# 6. Enter the container
./scripts/enter.sh

# 7. Start the project agent
claude --dangerously-skip-permissions   # agent: claude
codex                                   # agent: codex
```

For Codex, log in once inside the container with `codex login --device-auth` (enable device code login in your ChatGPT security settings first), or copy an existing `~/.codex/auth.json` into `my-app/codex-data/`. The login is kept in `codex-data/`.

## Daily Development

```bash
cd ~/projects/my-app
./scripts/start.sh    # if the container is not running
./scripts/enter.sh
claude --dangerously-skip-permissions   # or: codex
```

## When the Firewall Blocks Something

The dev container can only reach an allowlist (Claude/OpenAI APIs, npm, PyPI, Go, crates.io, GitHub, VS Code). The agent is instructed to tell you which domain it needs. To allow it:

```bash
cd ~/projects/my-app
# add the domain to "extra_allowed_domains" in project-config.json, e.g. ["huggingface.co"]
./scripts/firewall.sh
```

`firewall.sh` swaps in the new allowlist atomically — no rebuild, no restart, running processes keep going. Run it too when a long-running container starts failing to reach an allowed service (CDN IP addresses rotate, and allowed IPs are resolved when the firewall is applied).

## Using VS Code

Start the container with `./scripts/start.sh`, then use the Dev Containers extension: **Dev Containers: Attach to Running Container…** → `devcontainer-my-app` → open `/workspace`.

Don't create a `devcontainer.json` and use "Reopen in Container": VS Code would start a separate container without the firewall and without the hardening that `start.sh` applies.

## Adjusting Infrastructure (Re-enter Bootstrap)

To change the Dockerfile, ports, services or allowed domains after the initial setup:

```bash
cd ~/projects/my-app
./scripts/bootstrap.sh
# Make adjustments inside the container, then exit

# Rebuild if the Dockerfile changed
./scripts/build.sh
./scripts/start.sh
```

Bootstrap keeps its memory from previous sessions.

## Changing Language/Framework

The project agent handles language installation. It will:
1. Update `repo/.devcontainer/Dockerfile` (review the change)
2. Ask you to exit and rebuild

```bash
exit
cd ~/projects/my-app
./scripts/build.sh
./scripts/start.sh
./scripts/enter.sh
```

## Stopping / Restarting

```bash
cd ~/projects/my-app
./scripts/stop.sh     # Stop and remove the container
./scripts/start.sh    # Recreate it and re-apply the firewall
```

Always restart through `start.sh`: the firewall rules live in the container's network namespace, so a plain `docker restart` brings the container back without them. `stop.sh` removes the container so it can't be started again without the firewall (for example from VS Code's container list), and `enter.sh` refuses to enter a container whose firewall is gone.

## Keeping Tools Up to Date

- **Bootstrap**: `init.sh` and `bootstrap.sh` check npm for the latest Claude Code and rebuild the Bootstrap image when a newer version is available or `templates/bootstrap/` changed. Set `BOOTSTRAP_CLAUDE_CHANNEL=stable` to follow the stable channel, or `BOOTSTRAP_AUTO_UPDATE=0` to skip the check. Projects created before this mechanism existed can update the shared image with `./lib/helpers.sh bootstrap`.
- **Project agent**: `build.sh` reinstalls the latest Claude Code or Codex on every build.

## Directory Layout

After completing the full setup:

```
~/projects/
├── claude-dev-workflow/     # This repo (tool)
│   ├── init.sh
│   ├── lib/helpers.sh       # Host-side helpers (image updates, firewall)
│   └── templates/
└── my-app/                  # Generated project
    ├── repo/                # Source code (git-versioned, managed by the project agent)
    │   ├── .devcontainer/Dockerfile
    │   └── CLAUDE.md or AGENTS.md
    ├── data/                # Persistent data (mounted at /data)
    ├── secrets/             # Credentials (mounted read-only at /secrets)
    ├── claude-data/         # Claude Code state and token copy (agent: claude)
    ├── codex-data/          # Codex login and config (agent: codex)
    ├── scripts/             # Host management scripts
    │   ├── build.sh         #   Build the dev container image
    │   ├── start.sh         #   Start the container + firewall
    │   ├── enter.sh         #   Enter the running container
    │   ├── stop.sh          #   Stop and remove the container
    │   ├── firewall.sh      #   Re-apply the allowlist without restarting
    │   └── bootstrap.sh     #   Re-enter Bootstrap
    ├── .bootstrap-claude/   # Bootstrap's Claude Code memory, state and /login credentials
    ├── .claude/settings.json  # Fallback copy of the Bootstrap permission policy
    ├── CLAUDE.md            # Bootstrap role instructions
    ├── bootstrap-manifest.md  # Bootstrap's decision log
    └── project-config.json  # Project config (agent, ports, allowed domains, …)
```

## Security Model

### Dev Container
- Runs as a non-root user with `--cap-drop=ALL` and `--security-opt no-new-privileges` (there is no working `sudo`)
- Each project has its own Docker network (`net-<project-name>`)
- Only its own `repo/`, `data/`, `secrets/` (read-only), agent state and `project-config.json` (read-only) are mounted
- `project-config.json` is validated by `start.sh` before any container is touched

### Firewall
- Applied from outside the container by a one-shot container built on the host from `templates/firewall/` (`claude-dev-firewall` image), sharing the dev container's network namespace. The dev container has no `NET_ADMIN` and never sees the firewall script, so the agent cannot disable or edit it
- Default-deny outbound; allows the domain allowlist plus `extra_allowed_domains`, GitHub's published IP ranges, and the host's /24 network (so services on the host, such as the MCP Search Server, are reachable)
- DNS only through Docker's embedded resolver; SSH only to allowlisted IPs; IPv6 blocked
- **Limits to be aware of:** the allowlist is enforced by IP address, so other sites served from the same CDN IPs as an allowed domain are reachable too; DNS lookups through Docker's resolver can still carry data out; GitHub is fully reachable

### Bootstrap Container
- Its permission policy is baked into the image as Claude Code managed settings, which project, local and user settings cannot override. Without asking, it may read files in the project directory, search the web, and edit `repo/` and `bootstrap-manifest.md`. It asks you before it edits `project-config.json` (which controls the firewall allowlist), writes `repo/.devcontainer/` or `repo/.claude/`, fetches a web page, or runs other commands. Bypass and auto permission modes are disabled
- It cannot read outside the project directory without asking, which keeps the mounted token file out of reach; `secrets/`, `claude-data/`, `codex-data/` and `.bootstrap-claude/` are hidden from it
- `scripts/`, `templates/` and `.claude/` are mounted read-only
- Runs with `--cap-drop=ALL` and `no-new-privileges`; the OAuth token is mounted as a read-only file (not visible in `docker inspect`)
- It has no firewall, because it needs to look up documentation (for example, users of custom base images). Web fetches ask first for that reason: a URL can carry data out

### What You Should Still Review
- The project agent can edit `repo/.devcontainer/Dockerfile`. `build.sh` builds it with full network access, and the resulting image runs for a few seconds before `start.sh` applies the firewall. Review `.devcontainer/` changes before running `build.sh`
- Bootstrap's permission prompts: approve `project-config.json` edits and web fetches only when you expect them
- Treat `repo/` as untrusted on the host: the agent can write `.git/hooks/` and `.git/config`, and git runs commands from both. Use git on `repo/` inside the container, or check those files before running git on it from the host

## Notes

- Project names must be lowercase alphanumeric with hyphens (e.g., `my-app`, `api-server`)
- Projects are created as sibling directories of this repo, and their scripts use this repo's `lib/` and `templates/`: don't move or delete it
- Git inside `repo/` is managed by the project agent (it initializes the repository on first run)
- Template changes only affect projects created afterwards; existing projects keep their generated scripts and Dockerfile
