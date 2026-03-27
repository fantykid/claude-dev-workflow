# Claude Dev Workflow

Reusable dual-role Claude Code development workflow with Docker isolation.

Two AI agents with distinct responsibilities work in separate containers:

- **Bootstrap Claude Code** — Manages project infrastructure: initializes directory structure, configures devcontainer, and handles ongoing adjustments.
- **Project Claude Code** — Handles actual development with full autonomy (`--dangerously-skip-permissions`) inside an isolated container with network firewall.

## Prerequisites

- Linux (tested on Ubuntu)
- Docker
- Git
- Claude Code credentials — run `claude login` on host before first use (creates `~/.claude/.credentials.json`)

## Quick Start: Create a New Project

```bash
# 1. Clone this repo into your projects directory
cd ~/projects
git clone git@github.com:fantykid/claude-dev-workflow.git

# 2. Run init (creates project as sibling directory)
cd claude-dev-workflow
./init.sh my-app
```

This automatically builds the Bootstrap image (first time only) and launches you into a Bootstrap container.

```bash
# 3. Inside the Bootstrap container, run the init command:
/init-project

# Describe your project idea in natural language, e.g.:
#   "I want to build a blog website"
#
# Bootstrap will auto-determine:
#   - Project type (web app, API, CLI, etc.)
#   - Ports to expose
#   - Required services
#
# Language/framework is left undecided unless you specify it.
# Wait for Bootstrap to finish creating all files, then:

exit
```

```bash
# 4. Build the dev container image
cd ~/projects/my-app
./scripts/build.sh

# 5. Start the container (applies firewall automatically)
./scripts/start.sh

# 6. Enter the container
./scripts/enter.sh

# 7. Start developing with Project Claude Code
claude --dangerously-skip-permissions
```

Project Claude Code will discuss technical choices with you, set up the project structure, then begin development.

## Daily Development

```bash
cd ~/projects/my-app
./scripts/enter.sh
claude --dangerously-skip-permissions
```

## Adjusting Infrastructure (Re-enter Bootstrap)

To modify devcontainer config, ports, services, or other infrastructure after initial setup:

```bash
cd ~/projects/my-app
./scripts/bootstrap.sh
# Make adjustments inside the container, then exit

# Rebuild if Dockerfile was changed
./scripts/build.sh
./scripts/start.sh
```

Bootstrap retains memory from previous sessions.

## Changing Language/Framework

Project Claude Code handles language installation. It will:
1. Update `repo/.devcontainer/Dockerfile`
2. Tell you to exit and rebuild

```bash
exit
cd ~/projects/my-app
./scripts/build.sh
./scripts/start.sh
./scripts/enter.sh
claude --dangerously-skip-permissions
```

## Stopping / Restarting

```bash
cd ~/projects/my-app
./scripts/stop.sh     # Stop the container
./scripts/start.sh    # Restart (re-applies firewall)
```

## Directory Layout

After completing the full setup:

```
~/projects/
├── claude-dev-workflow/    # This repo (tool)
│   ├── init.sh
│   └── templates/
└── my-app/                 # Generated project
    ├── repo/               # Source code (git-versioned, managed by Project CC)
    │   ├── .devcontainer/
    │   ├── src/
    │   └── CLAUDE.md
    ├── data/               # Persistent data (survives container restarts)
    ├── secrets/            # Credentials (mounted read-only in container)
    ├── scripts/            # Host management scripts
    │   ├── build.sh        #   Build devcontainer image
    │   ├── start.sh        #   Start container + firewall
    │   ├── enter.sh        #   Enter running container
    │   ├── stop.sh         #   Stop container
    │   └── bootstrap.sh    #   Re-enter Bootstrap
    └── project-config.json # Project config (ports, type, services)
```

## Security Model

### Host Protection
- Host only needs git + Docker installed, nothing else
- All development happens inside containers
- No container has access to host filesystem beyond its own project directory

### Container Isolation
- Each project runs in its own Docker container and network (`net-<project-name>`)
- **Outbound firewall** (default-deny): only allows Claude API, npm registry, GitHub, and a few other whitelisted domains
- Firewall is applied externally via a one-shot privileged container — the development container has **no** `NET_ADMIN` capability and cannot modify firewall rules
- Secrets are mounted read-only

### Bootstrap Confinement
- Bootstrap can only write to its own project directory
- Management scripts and templates are mounted read-only into the container
- `settings.json` restricts dangerous operations (no `sudo`, `docker`, `rm -rf`)

## Notes

- Project names must be lowercase alphanumeric with hyphens (e.g., `my-app`, `api-server`)
- Projects are created as sibling directories to this repo
- Git inside `repo/` is managed by Project Claude Code (auto-initializes on first run)
