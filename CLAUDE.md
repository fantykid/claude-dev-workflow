# Claude Dev Workflow — Development Guide

## What This Project Is

A **dual-role Claude Code development workflow** with Docker isolation. It generates isolated dev container projects, each with:
- **Bootstrap Claude Code** — initializes project infrastructure (Dockerfile, config, directory structure)
- **Project Claude Code** — does actual development inside a firewall-restricted container

The entry point is `init.sh <project-name>`, which creates a sibling directory with scripts, templates, and config.

## Architecture

```
claude-dev-workflow/          ← THIS REPO (tool)
├── init.sh                   ← Entry point: creates new projects
└── templates/
    ├── bootstrap/            ← Bootstrap container image + config
    │   ├── Dockerfile        ← Bootstrap image (minimal: node:20 + Claude Code)
    │   ├── CLAUDE.md         ← Role instructions for Bootstrap CC
    │   └── claude-config/    ← Bootstrap permissions + slash commands
    │       ├── settings.json ← Permission allowlist/denylist
    │       └── commands/
    │           └── init-project.md  ← /init-project command logic
    ├── claude/
    │   └── CLAUDE.md         ← Role instructions for Project CC (template)
    ├── devcontainer/         ← Dev container templates
    │   ├── Dockerfile        ← Default dev image (node:20 base)
    │   ├── devcontainer.json ← VS Code devcontainer config
    │   └── init-firewall.sh  ← iptables/ipset firewall rules
    ├── scripts/              ← Host management script templates
    │   ├── build.sh          ← Build dev container image
    │   ├── start.sh          ← Start container + apply firewall
    │   ├── enter.sh          ← Enter running container
    │   ├── stop.sh           ← Stop container
    │   └── bootstrap.sh      ← Re-enter Bootstrap
    └── gitignore             ← .gitignore template for generated projects
```

### Data Flow

1. `init.sh my-app` → creates `../my-app/` with scripts (sed-substituted from templates) and launches Bootstrap container
2. Bootstrap reads `templates/` (read-only mount), asks user what they want, generates `repo/.devcontainer/` and `project-config.json`
3. User runs `build.sh` → builds dev container image from `repo/.devcontainer/Dockerfile`
4. User runs `start.sh` → starts container, applies firewall via external one-shot container, sets up MCP/GPU/ports
5. User runs `enter.sh` → enters container, starts `claude --dangerously-skip-permissions`

### Template Placeholder System

Scripts use `{{PLACEHOLDER}}` syntax, replaced by `init.sh` via `sed`:
- `{{PROJECT_NAME}}` — project name (lowercase alphanumeric + hyphens)
- `{{PROJECT_DIR}}` — absolute path on host
- `{{REPO_DIR}}` — path to this repo (for templates access)

Bootstrap uses different placeholders that it replaces itself:
- `{{ADDITIONAL_PACKAGES}}` — language/framework packages in Dockerfile
- `{{GSTACK_DEPS}}` / `{{GSTACK_INSTALL}}` — gstack-related Dockerfile sections
- `{{CONTAINER_USER}}` — in devcontainer.json
- `{{PROJECT_DESCRIPTION}}` — in CLAUDE.md for Project CC

## Security Model (Critical)

This project is **public on GitHub**. Security is the top priority.

### Container Isolation
- Dev containers run with `--cap-drop=ALL --security-opt no-new-privileges`
- Containers have **no NET_ADMIN** capability — cannot modify firewall
- Firewall is applied by a separate one-shot container sharing the network namespace
- Default policy: DROP all traffic, then allow only whitelisted domains

### Firewall (init-firewall.sh)
- Whitelisted domains: GitHub (via API meta), npm registry, Claude API, Sentry, Statsig, VS Code marketplace
- GitHub IPs added with `timeout 0` (permanent)
- Domain IPs resolved via DNS, also `timeout 0`
- IPv6 fully blocked (only loopback allowed)
- Verification: confirms example.com is blocked and api.github.com is reachable

### Token Handling
- OAuth token stored in `~/.claude/.oauth-token` on host (must be chmod 600)
- Mounted as file into container, loaded via `/etc/profile.d/` script
- **Never** passed as environment variable to `docker run` (visible in `docker inspect`)
- Bootstrap container still uses `-e CLAUDE_CODE_OAUTH_TOKEN=...` (known issue, see below)

### Bootstrap Confinement
- `settings.json` restricts: no sudo, no docker, no rm -rf, no curl, no wget, no git
- `scripts/` and `templates/` mounted read-only
- Can only write to `repo/`, `project-config.json`, `bootstrap-manifest.md`

## Known Issues / TODOs

- Bootstrap container passes OAuth token via environment variable (should use file mount like start.sh)
- `init.sh` also passes token via env var — same fix needed
- `enter.sh` partial container name matching (`docker ps -f "name=..."` can match substrings)
- Bootstrap `settings.json` allows `Bash(cat *)`, `Bash(sed *)`, `Bash(cp *)` without path restriction to /workspace

## Development Guidelines

### Making Changes
1. **Template changes** affect all *future* projects (not existing ones)
2. Test changes by creating a new test project: `./init.sh test-xxx`
3. After testing, delete the test project directory
4. Always check: does this change break existing projects that use older templates?

### Script Templates (templates/scripts/)
- These become the `scripts/` directory in generated projects
- Placeholders are replaced by `init.sh` at project creation time
- Changes here only affect newly created projects
- `start.sh` is the most complex — handles ports, GPU, MCP, firewall, token

### Dockerfile Templates
- `templates/devcontainer/Dockerfile` — default dev container (node:20 base)
- `templates/bootstrap/Dockerfile` — Bootstrap container (minimal)
- Custom base images are handled by Bootstrap following rules in `init-project.md`

### init-firewall.sh
- Baked into the dev container image at build time
- Changes require `build.sh` rebuild to take effect (stop/start alone is not enough)
- Must preserve Docker DNS NAT rules during iptables flush

### project-config.json Schema
```json
{
  "project_name": "string",
  "project_type": "web|api|cli|automation|ai-ml|mobile|experimental",
  "description": "string",
  "language": "string|undecided",
  "framework": "string|undecided",
  "ports": [3000],
  "services": [],
  "mcp_search": true,
  "gstack": false,
  "gpu": false,
  "container_user": "node"
}
```
- `container_user` determines all paths in start.sh/enter.sh
- `gpu: true` adds `--gpus all` flag (requires nvidia-container-toolkit on host)
- `gstack: true` installs Bun + Playwright + gstack in Dockerfile

## Git Conventions

- This repo is public on GitHub — never commit tokens, credentials, or paths containing sensitive info
- Commit messages in English, code comments may be in Chinese (zh-TW)
- Test on a fresh `init.sh` project before pushing changes
