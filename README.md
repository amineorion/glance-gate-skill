# glance-gate

> Make your Dockerfile small and secure — as a Claude Code skill. Local-first, open source.

`glance-gate` is a [Claude Code](https://docs.claude.com/en/docs/claude-code) skill that takes a project and produces:

- A `Dockerfile_final` — typically **5–60 MB**, from `scratch` or `alpine`/`distroless` when the stack allows.
- A CVE scan (Trivy / Grype / Docker Scout).
- An SPDX SBOM (Syft).
- A tier-aware markdown report.

Nothing leaves your machine. The skill runs inside your Claude Code session against your filesystem, your Docker daemon, and your Anthropic key.

License: **Apache 2.0**.

### Verified result

Real-world Node monorepo (113 controllers + 55 workspace plugins, mongoose + express + socket.io stack):

| | Baseline (Alpine) | glance-gate Tier 0 | Δ |
|---|---|---|---|
| Image content size | 87.34 MB | **45.35 MB** | −48% |
| Disk usage | 480 MB | **175 MB** | −63% |
| CRITICAL + HIGH CVEs | 35 | **0** | **−100%** |
| Total CVEs | 48 | **0** | **−100%** |
| Layers | 21 | 10 | −52% |

Smoke-tested under a real Mongo: 113 controllers + 55 plugins serving, SIGTERM clean exit in 190 ms.

## Install

```bash
git clone https://github.com/amineorion/glance-gate-skill.git
cp -R glance-gate-skill ~/.claude/skills/glance-gate
# restart Claude Code
```

Verify it loaded:

```
/skills
```

You should see `glance-gate` in the list.

## Use

In any project:

```
/glance-gate optimize this Dockerfile
```

Or just describe what you want:

> Make this image smaller and harder to attack.

The skill will:

1. Detect the language (Node / Python / Go / Rust / Java / Ruby) and framework.
2. Run a **bundle audit** against the entry file — counts dynamic imports, native bindings, decorator-side-effect patterns. Comes back with `RECOMMENDED_TIER={0|1|2}`.
3. (Optional) Fetch consolidated learnings from the glance-gate learning API to skip discovery on similar stacks.
4. Attempt the **tier ladder**:
   - **Tier 0** — single-binary on `alpine:3.20+` (Node via bun-compile musl, Ruby/Python via musl wheels) or `FROM scratch` (Go, Rust, Java GraalVM native-image with `--libc=musl`).
   - **Tier 1** — bundled artifact on `gcr.io/distroless/<lang>:nonroot`.
   - **Tier 2** — pnpm/pip/bundler deploy + scorched-earth cleanup → distroless.
5. **Smoke-test every successful build** — `scripts/smoke-test.sh` spins up an optional sidecar DB (Mongo/Postgres/Redis), publishes the port, runs HTTP probes, verifies the process uid, sends SIGTERM with a deadline.
6. Soft fall-through: build or smoke fail → drop one tier and retry.
7. Harden (non-root, exec-form CMD, pinned base).
8. Scan + SBOM.
9. Write: `Dockerfile_final`, `.dockerignore`, `scan-optimized.txt`, `sbom.spdx.json`, `bundle-audit.md`, `glance-gate-report.md`.

## Required local tools

| Purpose | Preferred | Fallback |
|---|---|---|
| Build | `docker` | — |
| CVE scan | [Trivy](https://aquasecurity.github.io/trivy) | [Grype](https://github.com/anchore/grype), `docker scout` (requires `docker login`) |
| SBOM | [Syft](https://github.com/anchore/syft) | Trivy SPDX |

```bash
# macOS
brew install aquasecurity/trivy/trivy syft

# Linux
curl -sSfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b /usr/local/bin
curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh    | sh -s -- -b /usr/local/bin
```

## What you get

| Stack | Typical baseline | Typical glance-gate output | Tier |
|---|---|---|---|
| Go service (pure-Go) | ~280 MB on `golang:1.22` | **8–25 MB** on `scratch` | 0 |
| Rust service (axum/actix) | ~120 MB on `rust:1.83` | **5–25 MB** on `scratch` (musl) | 0 |
| Node + Express / Fastify | ~280 MB on `node:20` | **40–60 MB** on `alpine:3.20` (bun-compile musl) | 0 |
| Node + plugin runtime (large) | ~480 MB on `node:20-alpine` | **45–80 MB** on `alpine:3.20` (after manifest generation) | 0 |
| Python FastAPI | ~480 MB on `python:3.12` | **80–150 MB** on `python:3.12-alpine` | 1 |
| Spring Boot 3 (jar) | ~440 MB on `eclipse-temurin:21` | **120–180 MB** on distroless/java21 | 1 |
| Spring Boot 3 (native-image) | same | **50–80 MB** on `scratch` (GraalVM `--libc=musl`) | 0 |
| Rails 7 API | ~520 MB on `ruby:3.3` | **70–130 MB** on `ruby:3.3-alpine` | 1 |

## File layout

```
glance-gate-skill/
├── SKILL.md                       # entry — Claude Code loads this
├── playbooks/
│   ├── optimization.md            # language-agnostic shrink playbook + musl-vs-glibc rule
│   ├── security.md                # hardening + scanning playbook
│   └── languages/{node,python,go,rust,java,ruby}.md   # tier ladders + framework gotchas
├── scripts/
│   ├── audit-node-bundle.sh       # Phase-1 audit: dynamic imports, native bindings, eval — prints RECOMMENDED_TIER
│   ├── regen-plugins-manifest.sh  # generates a static plugins.generated.ts from package.json
│   ├── smoke-test.sh              # sidecar DB + HTTP probes + uid check + SIGTERM deadline
│   ├── measure-image.sh           # size, layers, delta-vs-baseline
│   ├── scan-cves.sh               # Trivy → Grype → Scout
│   ├── make-sbom.sh               # Syft → Trivy
│   └── glance-api.sh              # talks to the optional learning API
└── templates/
    ├── Dockerfile.node-bun-alpine        # Tier 0 (verified 45 MB / 0 CVEs)
    ├── Dockerfile.node-distroless-bundled # Tier 1
    ├── Dockerfile.node-distroless        # legacy
    ├── Dockerfile.node-alpine            # legacy fallback
    ├── Dockerfile.python-distroless
    ├── Dockerfile.go-scratch
    ├── Dockerfile.java-layered
    └── Dockerfile.ruby-slim
```

## The learning API (optional)

When [`glance-api.sh`](scripts/glance-api.sh) can reach `https://api.glance-gate.com`, the skill:

- Calls `recall` to fetch winning strategies + canonical lesson articles for the current stack — keyed on language, framework, and dependencies.
- Calls `record` and `articles submit` after the run, contributing to the shared learning pool.

The helper auto-bootstraps a device token on first call. All article submissions are **AES-256-CBC + HMAC-SHA256 encrypted** with a per-device key (issued at auth, stored at `~/.glance-gate/key`, mode 0600). If the API is unreachable, the skill works fully offline — recall/record are best-effort, never load-bearing.

To point at a different API (self-host, dev cluster), set `GLANCE_API_URL=https://your-api`.

## Trust model

- The skill **never reads files outside the project working directory**.
- All AI inference runs through your own Claude Code session against your Anthropic key.
- The skill makes **zero outbound network calls of its own**. `docker`, `trivy`, `syft` do their own network — the same as if you ran them by hand.
- The optional learning API adds opt-in network. Each call is explicit; nothing happens in the background.

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md). The most useful contributions:

1. **Language overlays** under [`playbooks/languages/`](playbooks/languages/) — Rust shipped; .NET, PHP, Elixir, Deno still open.
2. **Dockerfile templates** under [`templates/`](templates/) with a measured expected size.
3. **Bug reports** with the input repo and the broken Dockerfile output.

## License

Apache 2.0. See [`LICENSE`](LICENSE).
