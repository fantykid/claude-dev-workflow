# Claude Dev Workflow — Development Guide

## What This Project Is

A **dual-role AI development workflow** with Docker isolation. It generates isolated dev container projects, each with:
- **Bootstrap Claude Code** — initializes project infrastructure (Dockerfile, config, agent guidance)
- **Project agent** — Claude Code (default) or OpenAI Codex CLI, doing the actual development inside a firewall-restricted container

The entry point is `init.sh <project-name>`, which creates a sibling directory with scripts and config, then launches Bootstrap.

## Architecture

```
claude-dev-workflow/          ← THIS REPO (tool)
├── init.sh                   ← Entry point: creates new projects
├── lib/
│   └── helpers.sh            ← Host-side helpers sourced by init.sh and generated scripts:
│                               Bootstrap/firewall image updates, extra_allowed_domains validation, firewall apply
└── templates/
    ├── bootstrap/            ← Bootstrap image (build context) + project files
    │   ├── Dockerfile        ← node:22-bookworm + Claude Code (version passed in by lib/helpers.sh)
    │   ├── managed-settings.json   ← Bootstrap permission policy → /etc/claude-code/ in the image
    │   ├── skills/init-project/SKILL.md ← /init-project → managed skill in the image
    │   ├── entrypoint.sh     ← Loads the OAuth token from a read-only file mount
    │   ├── CLAUDE.md         ← Role instructions for Bootstrap CC (copied into each project)
    │   └── claude-config/settings.json ← Fallback copy of the policy (copied into each project, mounted read-only)
    ├── claude/               ← Guidance for agent: claude
    │   ├── CLAUDE.md         ← Project CC instructions ({{PROJECT_DESCRIPTION}})
    │   ├── rules/            ← project-goals.md, decisions.md
    │   └── skills/           ← review-progress, create-skill
    ├── codex/skills/         ← review-progress, create-skill for agent: codex (.agents/skills)
    ├── devcontainer/
    │   └── Dockerfile        ← Default dev image (node:22-bookworm, AGENT_INSTALL block)
    ├── firewall/             ← claude-dev-firewall image (build context)
    │   ├── Dockerfile        ← debian:bookworm-slim + iptables/ipset/dig/curl
    │   └── init-firewall.sh  ← Apply (default) or --refresh the allowlist
    ├── scripts/              ← Host management script templates
    │   ├── build.sh          ← Build dev container image
    │   ├── start.sh          ← Validate config, start container, apply firewall, MCP/GPU/ports
    │   ├── enter.sh          ← Enter running container (login shell)
    │   ├── stop.sh           ← Stop container
    │   ├── firewall.sh       ← Re-apply the allowlist to a running container
    │   └── bootstrap.sh      ← Re-enter Bootstrap
    └── gitignore             ← .gitignore template for generated projects
```

### Data Flow

1. `init.sh my-app` → ensures the Bootstrap image is current (`ensure_bootstrap_image`), creates `../my-app/` with sed-rendered scripts, launches the Bootstrap container
2. Bootstrap (`/init-project`) reads `templates/` (read-only), asks the user, writes `repo/.devcontainer/Dockerfile`, `project-config.json`, `repo/CLAUDE.md` or `repo/AGENTS.md`, self-management files, `bootstrap-manifest.md`
3. `build.sh` → builds the dev image from `repo/.devcontainer/Dockerfile` (agent install layer re-runs on every build)
4. `start.sh` → validates `project-config.json`, ensures the firewall image, removes the old container, allocates ports, starts the container, applies the firewall through a one-shot `claude-dev-firewall` container, configures MCP servers
5. `enter.sh` → `bash --login` as `container_user`; the user starts `claude --dangerously-skip-permissions` or `codex`
6. `firewall.sh` → re-applies the allowlist (`extra_allowed_domains`, rotated IPs) with an atomic ipset swap

### Template Placeholder System

Scripts use `{{PLACEHOLDER}}` syntax, replaced by `init.sh` via `sed`:
- `{{PROJECT_NAME}}` — project name (lowercase alphanumeric + hyphens)
- `{{PROJECT_DIR}}` — absolute path on host
- `{{REPO_DIR}}` — path to this repo (templates and `lib/helpers.sh`)

Bootstrap fills these itself:
- `# {{ADDITIONAL_PACKAGES}}` — language/framework packages in the Dockerfile (usually left empty)
- `# === AGENT_INSTALL BEGIN/END ===` — Claude Code install by default; replaced with the Codex install for `agent: codex`
- `{{PROJECT_DESCRIPTION}}` — in `templates/claude/CLAUDE.md`
- `{{PROJECT_GOALS}}` — in `templates/claude/rules/project-goals.md`

## Security Model (Critical)

This project is **public on GitHub**. Security is the top priority, balanced with usability: hard boundaries live on the host, while the project agent keeps full autonomy inside its container.

### Dev Container Isolation
- `--cap-drop=ALL --security-opt no-new-privileges`, non-root `container_user` (sudo cannot work)
- No `NET_ADMIN`; the firewall script is not in the dev image at all
- `--restart no`: firewall rules live in the container's network namespace and are applied by `start.sh`
- `project-config.json` is treated as untrusted input (Bootstrap writes it): `agent`, `container_user` (`^[a-z_][a-z0-9_-]{0,31}$`, not root), ports and `extra_allowed_domains` are validated before any container is touched; optional `docker run` arguments are passed as a bash array
- Trust boundary: the project agent can edit `repo/.devcontainer/Dockerfile`, which takes effect on the next `build.sh` — users should review Dockerfile diffs

### Firewall (templates/firewall/)
- Runs from the host-built `claude-dev-firewall` image via `--network container:<dev container>` with `NET_ADMIN`/`NET_RAW`; `ensure_firewall_image` rebuilds it when `templates/firewall/` changes (content hash label)
- Default-deny outbound. Allowed:
  - **Claude Code**: api.anthropic.com, platform.claude.com, sentry.io, statsig.com (sentry/statsig kept in line with the official devcontainer)
  - **Codex / OpenAI**: api.openai.com, auth.openai.com, chatgpt.com, openai.com
  - **Package registries**: npm, PyPI (pypi.org, files.pythonhosted.org), Go (proxy.golang.org, sum.golang.org), Rust (crates.io, static.crates.io, index.crates.io)
  - **GitHub**: `api.github.com/meta` web/api/git IPv4 ranges, plus codeload.github.com
  - **IDE**: VS Code marketplace, blob, update, and server download hosts
  - **Per project**: `extra_allowed_domains` from `project-config.json`
  - Host /24 (MCP Search Server on the host) and 172.30.0.0/24 (notes MCP network)
- DNS only to Docker's embedded resolver (127.0.0.11); SSH only to allowlisted IPs; IPv6 blocked except loopback
- Each domain is resolved with retries; a domain that still fails is skipped with a warning (non-fatal)
- `--refresh` builds a new ipset and swaps it in atomically, then verifies; on failure it swaps the old set back
- Verification: example.com blocked (skipped if its IPs are allowlisted), external DNS server blocked, api.github.com reachable
- Must preserve Docker DNS NAT rules when flushing iptables

### Token Handling
- OAuth token stored in `~/.claude/.oauth-token` on the host (must be chmod 600); never passed with `docker run -e`
- Dev container (`agent: claude`): copied into `claude-data/`, exported by `/etc/profile.d/claude-token.sh` in login shells
- Bootstrap: mounted read-only at `/run/secrets/claude-oauth-token`, exported by the image entrypoint (which keeps an existing `CLAUDE_CODE_OAUTH_TOKEN` for older `bootstrap.sh` scripts)

### Bootstrap Confinement
- Policy = Claude Code **managed settings** in the image (`/etc/claude-code/managed-settings.json`, root-owned): `allowManagedPermissionRulesOnly`, `permissions.disableAutoMode`, `permissions.disableBypassPermissionsMode`, `strictPluginOnlyCustomization: true`
- Allowed without prompting: Read/Glob/Grep, WebSearch/WebFetch, `Edit(//workspace/repo/**)`, `Edit(//workspace/project-config.json)`, `Edit(//workspace/bootstrap-manifest.md)`; writes under `repo/.devcontainer/` and `repo/.claude/` still prompt (protected paths)
- `/init-project` is a managed skill (`/etc/claude-code/.claude/skills/init-project/`)
- Mounts: `scripts/`, `templates/`, `.claude/` read-only; `secrets/`, `claude-data/`, `codex-data/`, `gstack-data/` hidden with tmpfs (only when they exist)
- `--cap-drop=ALL --security-opt no-new-privileges`; no firewall (Bootstrap needs web documentation)
- `ensure_bootstrap_image` rebuilds the image when npm has a newer Claude Code or `templates/bootstrap/` changed, and refuses to use an old image without the policy

## Known Issues / TODOs

- The firewall allowlists IP addresses: other sites on the same CDN IPs as an allowed domain are reachable (verified with Cloudflare). A domain/SNI-filtering egress proxy would close this
- DNS queries through Docker's embedded resolver can still carry data out
- The Bootstrap container has unrestricted network access
- Existing projects keep their old scripts and Dockerfile. Projects whose `repo/.devcontainer/init-firewall.sh` still treats a failed DNS lookup as fatal now abort on `start.sh`, because `statsig.anthropic.com` no longer resolves — remove that domain from the project's script and rebuild
- Node.js 22 reaches end of life on 2027-04-30; bump both base images before then
- VS Code "Attach to Running Container" downloading its server inside the firewalled container is not covered by automated tests

## Development Guidelines

### Making Changes
1. **Template changes** affect all *future* projects (not existing ones)
2. Test changes by creating a new test project: `./init.sh test-xxx`
3. After testing, delete the test project directory (and its container, network and image)
4. Always check: does this change break existing projects that use older templates? The shared images (`bootstrap-claude`, `claude-dev-firewall`) are used by every project

### Script Templates (templates/scripts/)
- These become the `scripts/` directory in generated projects; placeholders are replaced at project creation time
- `start.sh`, `firewall.sh` and `bootstrap.sh` source `{{REPO_DIR}}/lib/helpers.sh`, so generated projects depend on this repo's location
- `start.sh` is the most complex — config validation, ports, GPU, agent persistence, firewall, MCP, token

### Dockerfile Templates
- `templates/devcontainer/Dockerfile` — node:22-bookworm; keep `/etc/profile.d/npm-global.sh`: Debian's `/etc/profile` resets `PATH` in login shells, which would hide `claude`/`codex`
- `templates/bootstrap/Dockerfile` — create directories before `COPY --chmod`: BuildKit applies the file mode to directories it creates, and a 644 directory makes the managed settings unreadable (Claude Code then refuses to start)
- Custom base images are handled by Bootstrap following the rules in `templates/bootstrap/skills/init-project/SKILL.md`

### Bootstrap Policy
- `templates/bootstrap/managed-settings.json` is the enforced policy; `claude-config/settings.json` must carry the same `permissions` block:
  `diff <(jq -S .permissions templates/bootstrap/managed-settings.json) <(jq -S .permissions templates/bootstrap/claude-config/settings.json)`
- Any change under `templates/bootstrap/` rebuilds the shared image on the next `init.sh`/`bootstrap.sh`

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
  "agent": "claude|codex",
  "mcp_search": true,
  "extra_allowed_domains": [],
  "gpu": false,
  "container_user": "node"
}
```
- `ports` only sets how many ports are needed; `start.sh` allocates host=container ports from 10000–19999 and passes `PORT`, `PORT_0`, `PORT_1`, …
- `agent` selects the Dockerfile install, the guidance file (CLAUDE.md or AGENTS.md), and auth/persistence/MCP handling
- `extra_allowed_domains`: plain domain names only (no wildcards), max 50; applied by `start.sh` and `firewall.sh`
- `notes_mcp` (optional, default true): set `false` to skip the notes MCP integration
- `container_user` determines paths in start.sh/enter.sh; must be a non-root user name
- `gpu: true` adds `--gpus all` (requires nvidia-container-toolkit on host)
- `gstack` is no longer supported; `start.sh` warns and ignores it

## Self-Management System

Generated projects include a self-management system that lets the project agent keep continuity across sessions.

### agent: claude (templates/claude/)
- **Rules** (`.claude/rules/`) are loaded every session unconditionally — goals, decisions, constraints
- **Skills** (`.claude/skills/`) are auto-discovered by description — repeatable workflows
- **Auto-memory** is built into Claude Code — no template config needed, just awareness in CLAUDE.md
- `templates/claude/CLAUDE.md` includes the "自我管理" section instructing CC to use all of the above

### agent: codex (templates/codex/)
- Goals and decisions live in `repo/docs/project-goals.md` and `repo/docs/decisions.md`; `AGENTS.md` tells Codex to read and maintain them
- Skills go in `repo/.agents/skills/<name>/SKILL.md` (Codex requires `name` and `description`)

### When Modifying Templates
- Changes to rules/skills templates affect ALL future projects
- Keep rules templates minimal (the project agent fills in the content)
- Skill descriptions must be specific enough for auto-discovery to work
- The `.gitignore` template keeps `.claude/skills/`, `.claude/rules/` and `.agents/` versioned
- Test the self-management flow: `init.sh test-xxx` → bootstrap → build → start → verify the agent knows its goals

## Git Conventions

- This repo is public on GitHub — never commit tokens, credentials, or paths containing sensitive info
- Commit messages in English, code comments may be in Chinese (zh-TW)
- Test on a fresh `init.sh` project before pushing changes
