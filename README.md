# Claude Dev Workflow

Reusable dual-role Claude Code development workflow with Docker isolation.

Two AI agents with distinct responsibilities work in separate containers:

- **Bootstrap Claude Code** — Manages project infrastructure: initializes directory structure, configures devcontainer, and handles ongoing adjustments.
- **Project Claude Code** — Handles actual development with full autonomy (`--dangerously-skip-permissions`) inside an isolated container with network firewall.

## Prerequisites

- Linux (tested on Ubuntu)
- Docker
- Git
- Claude Code credentials (`claude login` on host)

## Quick Start

```bash
# Clone into your projects directory
cd ~/projects
git clone https://github.com/<your-username>/claude-dev-workflow.git

# Create a new project (created as sibling directory)
cd claude-dev-workflow
./init.sh my-app
```

This launches a Bootstrap container where you describe your project idea. Bootstrap auto-determines project type, ports, and services.

After Bootstrap exits:

```bash
cd ~/projects/my-app
./scripts/build.sh                    # Build dev container image
./scripts/start.sh                    # Start container + firewall
./scripts/enter.sh                    # Enter container
claude --dangerously-skip-permissions # Start developing
```

## Directory Layout

After running `./init.sh my-app`:

```
~/projects/
├── claude-dev-workflow/    # This repo (tool)
│   ├── init.sh
│   └── templates/
└── my-app/                 # Generated project
    ├── repo/               # Source code (git-versioned)
    │   ├── .devcontainer/
    │   ├── src/
    │   └── CLAUDE.md
    ├── data/               # Persistent data
    ├── secrets/            # Credentials (read-only in container)
    ├── scripts/            # Management scripts
    │   ├── build.sh
    │   ├── start.sh
    │   ├── enter.sh
    │   ├── stop.sh
    │   └── bootstrap.sh
    └── project-config.json
```

## Management Scripts

| Script | Purpose |
|--------|---------|
| `scripts/build.sh` | Build the devcontainer image |
| `scripts/start.sh` | Start container, apply firewall, configure ports |
| `scripts/stop.sh` | Stop the container |
| `scripts/enter.sh` | Enter the running container |
| `scripts/bootstrap.sh` | Re-enter Bootstrap to adjust infrastructure |

## Security Model

### Host Protection
- Host only needs git + Docker installed, nothing else
- All development happens inside containers
- No container has access to host filesystem beyond its project directory

### Container Isolation
- Each project runs in its own Docker container and network
- **Outbound firewall** (default-deny): only allows Claude API, npm registry, GitHub, and a few other whitelisted domains
- Firewall is applied externally via a one-shot privileged container — the development container has **no** `NET_ADMIN` capability and cannot modify firewall rules
- Secrets are mounted read-only

### Bootstrap Confinement
- Bootstrap can only write to its project directory
- Management scripts and templates are mounted read-only
- `settings.json` restricts dangerous operations (no `sudo`, `docker`, `rm -rf`)

## Development Flow

Project Claude Code follows a structured workflow:

1. **Discuss** — Talk with you about requirements, language, and framework
2. **Scaffold** — Create directory structure, initialize project, commit scaffold
3. **Develop** — Write code within the established structure

Language and framework installation is handled by Project Claude Code: it updates the Dockerfile, then you rebuild the container.

## Re-entering Bootstrap

To adjust infrastructure after initial setup:

```bash
cd ~/projects/my-app
./scripts/bootstrap.sh
```

Bootstrap retains memory from previous sessions and can modify devcontainer config, ports, services, etc.

## Notes

- Project names must be lowercase alphanumeric with hyphens (e.g., `my-app`, `api-server`)
- Projects are created as sibling directories to this repo
- Git version control inside `repo/` is managed by Project Claude Code
- Auto backup is currently disabled
