# Optimization playbook (language-agnostic)

The job: shrink the final image as much as the stack allows without breaking the runtime.

## Levers, in order of impact

1. **Base image** — `scratch` < `distroless/static` < `distroless/<lang>` < `alpine` < `*-slim` < full-fat. Pick the smallest that still runs your binary.
2. **Multi-stage separation** — toolchain stays in the builder, runtime only carries the artifact + its direct deps.
3. **Bundle / static-compile to a single artifact** — when reachable, this collapses `node_modules` / `site-packages` entirely (see "Tier 0" below).
4. **Scorched-earth dep cleanup** — only when you couldn't bundle. Strip docs, tests, source maps, typings, examples from `node_modules` / `site-packages` / equivalents.

## Tier 0 — single-binary on `FROM scratch` (when reachable)

When a stack can produce a single statically-linked artifact, the runtime
image collapses to that one file plus a few system files. There is no
`node_modules` to clean, no package manager to attack, no shell to exploit.

| Language | Tier-0 path | Final base | Reachability |
|---|---|---|---|
| Go | `CGO_ENABLED=0 go build -trimpath -ldflags="-s -w"` | `FROM scratch` | Almost always. The friendliest target. |
| Rust | `cargo build --release --target x86_64-unknown-linux-musl` | `FROM scratch` | Usually, unless dynamic-linking a C library. |
| Node / TS | esbuild bundle → `bun build --compile --target=*-musl` | `alpine:3.20+` (bun is dynamically musl-linked) | If no `eval`, no truly-dynamic imports (a generated plugins manifest solves the common ones), no `.node` bindings. The skill's `audit-node-bundle.sh` decides. |
| Java | GraalVM `native-image` | `gcr.io/distroless/base-debian12` (statically-linked native) | If the codebase tolerates AOT — reflection-heavy frameworks need hints. |
| Python | PyInstaller / Nuitka | `FROM distroless/static` | Rare. Most apps with C extensions break the bundler. |
| Ruby | — | — | Not reachable in practice (no production-grade compiler). |

Run the language overlay's audit step *before* deciding the tier. Tier 0
is the goal; Tier 1 (bundled artifact on `distroless/<lang>`) is the soft
fallback; Tier 2 (full deps tree on `distroless/<lang>`) is the floor.

## Verified reductions — what to expect

Cross-language benchmark on the realworld.io backend spec (6 canonical
implementations, one per supported language, naive single-stage
baselines vs glance-gate-generated Dockerfiles, 2026-05-19):

| Language | Stack | Baseline | Optimized | Reduction |
|---|---|---|---|---|
| Go | gin + gorm/sqlite (CGO) | 372 MB | **13 MB** | **−96.5%** |
| Rust | actix-web + diesel/pg (libpq) | 749 MB | **34 MB** | **−95.5%** |
| Python | FastAPI 0.79 + asyncpg + psycopg2-binary | 410 MB | **28 MB** | **−93.3%** |
| Node | Express + Prisma 4 + Nx workspace | 581 MB | **51 MB** | **−91.2%** |
| Java | Spring Boot 2.6 + DGS GraphQL + SQLite | 649 MB | **144 MB** | **−77.8%** |
| Ruby | Rails 4.2.6 (2016-era) | — | — | unbuildable (see ruby.md) |

**Mean: −90.9%. Total saved across the 5 working repos: 2.49 GB.**

Production proof point (edorer/user-api, Node monorepo with 113
controllers + 55 workspace plugins) starting from an **already
Alpine-optimized baseline** (not a naive single-stage one): 87 MB →
45 MB content (**−48%**), 480 MB → 175 MB disk (**−63%**), **48 CVEs
→ 0**.

What the spread means:

- **Static-compile languages (Go, Rust) hit the ceiling.** Single binary
  on `FROM scratch` / `alpine` is a 95%+ reduction from the same code
  running on `<lang>:latest`.
- **Interpreted runtimes (Node, Python, Ruby) cluster around −90%.**
  Bundle the entry, drop dev deps, ship on alpine/distroless.
- **JVM has a real floor.** ~144 MB is the layered-jar minimum for
  Spring Boot + an HTTP server + Jackson + reflection. Breaking under
  it requires GraalVM native-image (Tier 0), which means Spring Boot
  3.x.
- **Already-optimized starting points** show smaller % deltas but
  reach the same absolute floor.

The skill's report should always cite both:
- The reduction percentage vs the *measured baseline* (the repo's own
  Dockerfile, or a naive single-stage if none exists).
- The absolute size achieved (which is the number that actually matters
  for registry storage, k8s pull times, supply-chain attack surface).

## musl vs glibc — the unfixed-CVE escape hatch

A consistent pattern across recent Trivy runs: Debian-based distroless
images (`distroless/nodejs20-debian12`, `distroless/cc-debian12`, etc.)
inherit several `libc6` / `libssl3` CVEs that Debian marks
`FixedVersion: -` — the upstream branch will not be patched. Examples:

- `CVE-2026-5435 / 5450 / 5928 / 6238` — glibc (4 MEDIUM)
- `CVE-2010-4756`, `2018-20796`, `2019-1010022/-23/-24/-25`, `2019-9192` — glibc (7 LOW)
- `CVE-2026-31789` — libssl3 (1 CRITICAL, regularly stale before GCR refresh)

**These disappear when the binary is musl-linked and ships on alpine.**
Verified result on edorer/user-api: 11 stuck CVEs → 0 by switching the
compile stage from `oven/bun:X.Y-debian` to `oven/bun:X.Y-alpine` and
the runtime from `distroless/base-nossl-debian12` to `alpine:3.20`.

Per-language route to musl:

| Language | musl path |
|---|---|
| Go | `CGO_ENABLED=0` already produces a static binary with no libc — ships on `FROM scratch`. No musl/glibc choice needed. |
| Rust | `--target x86_64-unknown-linux-musl` (or `aarch64-unknown-linux-musl`) for fully static binary on `FROM scratch`. |
| Node | esbuild bundle → `bun build --compile --target=bun-linux-{x64,arm64}-musl`, ship on `alpine:3.20+` + `libstdc++ libgcc ca-certificates tzdata`. |
| Java | GraalVM native-image with `--static --libc=musl` (Linux x86_64 only as of GraalVM 22+). Ships on `FROM scratch` or `alpine`. |
| Python | Wheels-only deps + `python:3.X-alpine`. C-extension wheels for musl exist for the big libs (numpy, pillow, lxml) but not for everything — test. |
| Ruby | `ruby:3.X-alpine` — same caveat, native gems vary in musl support. |

The rule: **prefer musl-linked binaries on alpine when a project's deps
support it**. The byte size is roughly equivalent; the CVE feed is
fresher; libssl3 / glibc CVE classes are eliminated.

Tradeoff to know: alpine ships a shell + `apk` (not in distroless). If
shell-less is a hard requirement, accept the distroless CVEs *or* run
`apk del apk-tools` post-install to strip the package manager. The
edorer Tier 0 result chose alpine for zero CVEs at the cost of a
shell-on-disk.

Soft-fallback rules the skill enforces:

1. Audit recommends Tier N.
2. Build Tier N. If `docker build` fails, drop to Tier N+1.
3. Run `scripts/smoke-test.sh`. If it fails, drop to Tier N+1.
4. Repeat until success or Tier 2 reached. Tier 2 must succeed — if it
   doesn't, the run is aborted and logged under `user_action_required`.

The final report names the tier that actually shipped and why higher tiers
were rejected. That signal is what `Phase 6 — record` uploads.

## Base image decision tree

| If | Prefer | Why |
|---|---|---|
| App compiles to a static binary (Go, Rust musl) | `scratch` or `distroless/static` | zero runtime deps |
| App is pure interpreted, no native addons | `distroless/<lang>` or `alpine` | smallest surface |
| App has native deps (sharp, bcrypt, Pillow, lxml…) | `*-slim` (glibc) | alpine's musl breaks native modules silently |
| Stack requires shell at runtime | `distroless/<lang>:debug` | keeps `sh`, drops the rest |

Never pin to `:latest`. Always use a specific minor version tag (e.g., `node:20.11-slim`, not `node:20-slim`).

## Multi-stage skeleton

```
Stage 1: builder     → full toolchain, compile/build
Stage 2: installer   → production-only deps + scorched-earth cleanup
Stage 3: runtime     → distroless/scratch, COPY --from=installer
```

- Most-cached steps first (lockfile, dep install). Most-changing last (source, build).
- Every `COPY --from=X` should copy the *minimum* — not whole directories when a single file works.
- Never `RUN apt-get update` in the runtime stage.

## Layer-order checklist

```dockerfile
# 1. Base + system deps (rarely changes)
FROM node:20.11-slim AS builder
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential python3 && rm -rf /var/lib/apt/lists/*

# 2. Lockfiles only (rarely changes — keeps install cached)
WORKDIR /app
COPY package.json package-lock.json ./

# 3. Dependency install (cached unless lockfile changes)
RUN npm ci

# 4. Source (changes every commit)
COPY . .

# 5. Build (fast, uses cached deps)
RUN npm run build
```

Reversing 2 and 4 is the single most common cache-busting mistake.

## Scorched-earth cleanup

After `npm ci --omit=dev` / `pip install --no-deps` / equivalent, remove what the runtime doesn't need:

- Docs, READMEs, CHANGELOGs, LICENSE.\* (keep one per legal — see your project policy)
- Tests, benchmarks, examples directories
- Source maps (`.map`), typings (`.d.ts`), TS sources where compiled JS is shipping
- Language caches: `__pycache__`, `*.pyc`, `.gradle/caches`
- Build-only system packages: purge after compile

Per-language specifics live in `playbooks/languages/<lang>.md`.

## Measuring

After every build:

```bash
./scripts/measure-image.sh <tag> [baseline-tag]
```

Prints total size in MB, layer count, top-5 largest layers, and a percentage delta vs baseline.

## When you can't shrink further

Escalate, each step more aggressive:

1. Try bundling / static compilation if not already.
2. Switch base: slim → alpine → distroless → scratch.
3. More aggressive dep cleanup (look for heavyweight packages — `aws-sdk` v2 is ~90 MB, `puppeteer` ships Chromium).
4. Strip symbols from compiled binaries.
5. Split build and runtime images entirely.

Some stacks have a real floor (Java with reflection-heavy frameworks bottoms out around 80–120 MB on distroless). Document the floor in the report; don't fabricate a smaller number.

## Anti-patterns

- `FROM ubuntu:latest`
- `RUN npm install` (mutates the lockfile) — use `npm ci`
- Copying the whole repo then `rm -rf` — the layer still contains it
- Installing dev deps then `--omit=dev` in the same stage — the install is cached but bloated; use a fresh stage
- `USER root` in the final stage
- Shell-form CMD (`CMD node server.js`) — swallows SIGTERM; container takes 10 s to die
