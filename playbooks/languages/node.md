# Node.js / TypeScript overlay

Pair with `playbooks/optimization.md` and `playbooks/security.md`. They tell
you *what*; this tells you *how* for Node.

## The three-tier ladder

Always start at the top. Drop only when the audit or a smoke-test failure
forces it. The skill enforces this with `scripts/audit-node-bundle.sh` in
Phase 1 — never write a candidate Dockerfile without running it first.

| Tier | Base | Strategy | Typical size | When |
|---|---|---|---|---|
| **0** | `alpine:3.20+` | esbuild bundle → `bun --compile --target=*-musl` static binary | **40–60 MB content / 150–200 MB disk** | No `eval`, no truly-dynamic imports (after manifest generation), no `.node` bindings the bundler can't externalize |
| **1** | `gcr.io/distroless/nodejs20-debian12:nonroot` | esbuild bundle → run via `node server.js`, no `node_modules` shipped | **60–110 MB content** | Bundleable but bun-compile fails on this codebase (rare with modern bun) |
| **2** | `gcr.io/distroless/nodejs20-debian12:nonroot` | `pnpm/npm deploy --prod` + scorched-earth cleanup | **120–250 MB content** | Plugin runtime that even a manifest can't make static, `eval`, or true runtime introspection |

Verified Tier 0 result (edorer/user-api, 113 controllers + 55 plugins,
pnpm monorepo): **45.35 MB content / 175 MB disk / 0 CVEs at every
severity**, 190 ms SIGTERM clean exit.

A working image at Tier 2 beats a broken one at Tier 0. But Tier 2 is the
floor — never stop there if Tier 1 or 0 was reachable.

## Detect

### Package manager

| File | Manager | Install command |
|---|---|---|
| `package-lock.json` | npm | `npm ci` |
| `yarn.lock` | yarn | `yarn install --frozen-lockfile` |
| `pnpm-lock.yaml` | pnpm | `pnpm install --frozen-lockfile` |
| `bun.lockb` / `bun.lock` | bun | `bun install --frozen-lockfile` |

Never `npm install` in a Dockerfile — it mutates the lockfile.

### Framework / pattern signals

| Framework | Signal | Bundling note |
|---|---|---|
| Express + raw routes | `"express"` in deps | Bundles cleanly. Tier 0 viable. |
| Fastify | `"fastify"` in deps | Bundles cleanly. Tier 0 viable. |
| Hono | `"hono"` in deps | Built for bun. Tier 0 is the default. |
| routing-controllers | dep present | Reflection-heavy — needs `--keep-names` + `--tree-shaking=false` (mandatory). Bundles cleanly with those flags. |
| NestJS | `"@nestjs/core"` | Tier 0 with bun preserves decorators; Tier 1 needs `nest build --webpack` for esbuild. |
| Next.js | `"next"` + `next.config.*` | Use `output: "standalone"`. Tier 1 only. |
| MikroORM / TypeORM | `@mikro-orm/*` / `typeorm` dep | Entity discovery happens at runtime via decorator side-effects — `--tree-shaking=false` mandatory. |

### Native modules — block bundling, break alpine

`bcrypt`, `sharp`, `better-sqlite3`, `canvas`, `argon2`, `node-sass`,
`@prisma/client`, `@tensorflow/tfjs-node`.

If any are present:
- Tier 0 is **out** unless every one is `--external`'d.
- Use `node:20.x-bookworm-slim` (glibc) for the bundle stage. Alpine's
  musl breaks node-gyp builds silently for many of these.
- Tier 1 with surgical `COPY --from=build /repo/node_modules/<pkg>` is
  the move. The audit script lists them.

### Plugin runtimes — the Tier-1 blocker (and unlock)

Watch for code like:

```ts
const mod = await import(row.package);     // bundler-blind
const mod = await import(entry.package);   // same
```

Two patterns surface this:
1. `dependencies` with many `workspace:*` entries (`>10` is a strong signal).
2. `await import(<variable>)` or `require(<variable>)` near a config-table lookup.

**Unlock — generate a static manifest:**

```bash
./scripts/regen-plugins-manifest.sh services/<name>/package.json \
  --pattern '@your-scope/plugin-*' \
  --out services/<name>/src/plugins.generated.ts
```

Then the skill is allowed to rewrite the two-line call site
(documented as build-metadata, not business logic):

```ts
// before
const mod = await import(row.package);
// after
import { plugins as pluginManifest } from './plugins.generated';
// ...
const loader = pluginManifest[row.package as keyof typeof pluginManifest];
if (!loader) { logger.error({ pkg: row.package }, 'plugin not in manifest'); continue; }
const mod = await loader();
```

After the rewrite, the audit returns `RECOMMENDED_TIER=0`.

## Phase 1 — Run the audit FIRST

```bash
./scripts/audit-node-bundle.sh src/main.ts /tmp/audit.md
# stdout last line:  RECOMMENDED_TIER=<0|1|2>
```

The audit (comment-aware as of 2026-05) reports:
- Workspace dep count
- Native `.node` bindings
- Non-literal dynamic imports (excluding `//` and `/* */` comments)
- `eval` / `new Function` call sites
- A recommended tier

Use it. Don't write a candidate Dockerfile without it.

## Tier 0 — bun-compile to alpine (preferred default, verified)

Template: `templates/Dockerfile.node-bun-alpine`.

Pipeline:
1. **esbuild bundle** in a `node:20.x-bookworm-slim` builder (glibc; pnpm/npm/yarn work here, alpine often breaks node-gyp prebuilds).
2. **`bun build --compile`** in `oven/bun:X.Y-alpine` — produces a static binary linked against musl + libstdc++ + libgcc.
3. **Ship on `alpine:3.20+`** with `libstdc++ libgcc ca-certificates tzdata` + a non-root `app` user.

### Mandatory esbuild flags

| Flag | Why |
|---|---|
| `--keep-names` | Preserves `Function.name` / `class.name` so `constructor.name` lookups still work. Frameworks that rely on this include Mongoose (`Schema.Types.ObjectId` check), routing-controllers, class-validator. Without it: `TypeError: Invalid schema configuration: '_ObjectId' is not a valid type`. |
| `--tree-shaking=false` | Keeps class declarations whose only "use" is a side-effect decorator. Patterns that break under default tree-shaking: `@Model`/`@Entity`/`@Module` decorators registering classes in a global registry, NestJS module discovery, MikroORM/TypeORM entity scanning. Without it: `Error: no model registered for "extends"` (the bundler dropped the class). |
| `--minify-whitespace` | Safe with `--keep-names`. |
| `--minify-syntax` | Safe with `--keep-names`. |

Do **not** add `--minify-identifiers` — it renames classes and breaks
`constructor.name` lookups even with `--keep-names` semantics.

### Externals — the resolver shortlist

Bundlers fail on peer/optional deps that aren't installed at bundle time.
Pre-emptively externalize the usual suspects:

```
--external:@tensorflow/tfjs-node
--external:kcors
--external:bufferutil
--external:utf-8-validate
--external:@nestjs/*
```

The audit shouldn't generate this — but if `npx esbuild` reports
"Could not resolve" on a peer dep, add it to the external list and retry.

### The `constructor.toString()` anti-pattern

When a codebase has lines like:

```ts
const src = instance.constructor.toString();
const m = /class\s+(\w+)/.exec(src);
return m ? m[1] : '';
```

…bundling breaks them. esbuild emits classes as `class extends Bar {...}`
(anonymous) or `var Foo = class { ... }` (assigned). The regex either
returns nothing or captures `extends`.

**Fix** (skill is allowed — this is framework-compat, not business logic):

```ts
const ctor = instance.constructor;
if (ctor && typeof ctor.name === 'string' && ctor.name) return ctor.name;
// fall back to the toString regex for the rare runtime that strips .name
const m = /class\s+(\w+)/.exec(String(ctor || ''));
return m ? m[1] : '';
```

Grep for `\.constructor\.toString\(\)` in the build closure before
shipping Tier 1 / 0.

## Tier 1 — esbuild bundle on distroless

Template: `templates/Dockerfile.node-distroless-bundled`.

Use when bun-compile fails on this codebase (rare; usually a bun
runtime incompatibility with a specific dep). Same esbuild flags as
Tier 0; runtime is `gcr.io/distroless/nodejs20-debian12:nonroot` and
launches the bundle directly with `node server.js`.

Inherits the same distroless base CVEs as Tier 2 (libssl3, libc6) —
prefer Tier 0 (alpine musl) when reachable.

## Tier 2 — pnpm/npm deploy + scorched earth

Use only when Tier 0 *and* Tier 1 are both unreachable (eval, file://
imports, or arbitrary `Function()` evaluation at runtime). The floor —
never the goal.

```dockerfile
FROM node:20.18-bookworm-slim AS build
WORKDIR /src
RUN corepack enable && corepack prepare pnpm@9.12.0 --activate
COPY . .
RUN --mount=type=cache,id=pnpm,target=/pnpm/store pnpm install --frozen-lockfile
RUN pnpm -F <app> build
RUN pnpm --filter=<app> --prod deploy /deploy && \
    cp -r services/<app>/dist /deploy/dist

# Safe scorched-earth — see "what's safe" below.
RUN find /deploy/node_modules \( \
       -type d \( \
          -name "test" -o -name "tests" -o -name "__tests__" \
       -o -name "examples" -o -name "samples" -o -name "man" \
       -o -name "manual" -o -name "benchmark" -o -name "benchmarks" \
       -o -name "coverage" -o -name "website" \
       -o -name ".github" -o -name ".husky" -o -name ".circleci" \
       -o -name ".vscode" -o -name ".idea" \
       \) \
    -o -type f \( \
          -name "*.md" -o -name "*.markdown" \
       -o -name "CHANGELOG*" -o -name "LICENSE*" -o -name "AUTHORS*" \
       -o -name "*.map" -o -name "*.d.ts.map" \
       -o -name "*.flow.js" -o -name "Makefile" \
       -o -name ".npmignore" -o -name ".eslintrc*" -o -name ".prettierrc*" \
       -o -name "karma.conf*" -o -name "jest.config*" \
       -o -name "webpack.config*" -o -name "rollup.config*" \
       -o -name "tsup.config*" -o -name "vite.config*" \
       -o -name "nyc.config*" \
       \) \
  \) -prune -exec rm -rf {} + 2>/dev/null || true && \
  find /deploy/node_modules -name '*.ts' ! -name '*.d.ts' -delete

FROM gcr.io/distroless/nodejs20-debian12:nonroot
WORKDIR /app
COPY --from=build --chown=65532:65532 /deploy /app
EXPOSE 3000
CMD ["dist/main.js"]
```

If you're shipping a `tsx` loader (`--import tsx`) in the runtime stage,
you've stopped optimizing — pre-compile the TS in the build stage.

### Scorched-earth cleanup — what's safe

Past landmines the skill has hit:

- `-name "doc"` (singular) — **never delete**. `exceljs` ships its
  core in `lib/doc/`.
- `-name "example"` (singular) — never delete. Several libs use it as
  a code path.
- `-name "*.json"` — never globally delete. Most packages read their
  own `package.json` at runtime.
- `-name "src"` — only safe outside workspace deps. Workspace packages
  that ship raw TS (`main: ./src/index.ts`) break.

Stick to plurals (`tests`, `examples`, `benchmarks`), filename globs
(`*.map`, `CHANGELOG*`), and dot-files (`.github`, `.eslintrc*`).

## Smoke test — required for every tier

```bash
./scripts/smoke-test.sh glance-gate-try-N \
  --with-db mongo \
  --env "JWT_SECRET=$(openssl rand -hex 32)" \
  --env "UPLOAD_DIR=/app/uploads" \
  --env "NODE_ENV=production" \
  --user-check 1000 \
  --probe /api/health/live=200 \
  --probe /nonexistent=404 \
  --sigterm-deadline 15
```

Verifies: container boots, optional sidecar DB resolves, HTTP probes
return the expected statuses, container runs as uid 1000, SIGTERM
graceful exit < 15s, single-line `SMOKE=PASS|FAIL` verdict for the
orchestrator.

If the smoke test fails, the tier did not work — drop one tier and try
again, even if `docker build` succeeded.

## Heavyweight offenders to look for

- `aws-sdk` v2 → ~90 MB. Migrate to modular v3.
- `puppeteer` → ships Chromium (~300 MB). Use `puppeteer-core` and
  supply a separate browser binary.
- `moment` → bundles all locales. Switch to `dayjs` or import only
  needed locales.
- `@tensorflow/tfjs-node` → 200+ MB. Split inference to a dedicated
  service.

## Prisma — the engine-binary problem

`@prisma/client` (4.x and 5.x) ships a separate, per-platform **query
engine binary** that's `dlopen`ed at runtime. Bundlers can't embed it.
Two gotchas, both bit us on the node-express realworld run:

1. **Builder must have `openssl`.** Prisma autodetects the libssl
   ABI; `node:20-bookworm-slim` doesn't include `openssl`, so Prisma
   silently picks the `linux-arm64-openssl-1.1.x` engine. That engine
   fails to load at runtime on `distroless/nodejs20-debian12` (libssl3
   only). Fix: `apt-get install -y --no-install-recommends openssl
   ca-certificates` before `npx prisma generate`.

2. **Externalize from esbuild + COPY surgically.** Add
   `--external:@prisma/client --external:.prisma/client` to the
   esbuild command, then on the runtime stage:

   ```dockerfile
   COPY --from=build /repo/node_modules/@prisma/client    /app/node_modules/@prisma/client
   COPY --from=build /repo/node_modules/.prisma/client    /app/node_modules/.prisma/client
   ```

   That's the *only* `node_modules/` content the runtime needs.

Tier 0 (bun-compile to alpine) is blocked on Prisma until 5.7+, which
ships `linux-musl-arm64-openssl-3.0.x` engines. Logged as
user_action_required on every Prisma-using run.

## Nx workspace pattern

Nx-generated Dockerfiles assume `dist/<app>` was pre-built on the host
(`nx docker-build api`), which doesn't work inside `docker build` without
a builder stage that runs `nx build` first. Bake the Nx build into the
builder stage:

```dockerfile
FROM node:20.18-bookworm-slim AS build
RUN apt-get install -y --no-install-recommends openssl ca-certificates
WORKDIR /repo
COPY . .
RUN npm ci
RUN npx prisma generate --schema=src/prisma/schema.prisma
# `nx build` writes to dist/api by default — esbuild then bundles that.
RUN esbuild src/main.ts ...
```

The audit script flags `package.json` with an `nx` field and prints a
hint.

## Gotchas (in order of how often they bite)

- **`.env` files leak** when `COPY . .` runs without a `.dockerignore`.
  Always add one. Especially for `.env.local`.
- **NestJS + esbuild = broken decorators.** Use `nest build --webpack`,
  or switch to Tier 0 with bun (which preserves decorators natively).
- **Next.js without `standalone`** ships the full `.next/` + node_modules
  → 400 MB+.
- **`tsx --import` in runtime** is a smell. It means the build never
  compiled TypeScript; you're shipping a TS interpreter to production.
- **`constructor.toString()` regex** anywhere in the framework code
  → bundling breaks it. Grep + fix before shipping. See template above.
- **Workspace dynamic imports + bundler** → silently picks the wrong
  target. Generate a plugin manifest first.
- **`mongoose._ObjectId is not a valid type`** at boot → missing
  `--keep-names`. Add it.
- **`Error: no model registered for "X"`** at boot → missing
  `--tree-shaking=false`. Add it.
