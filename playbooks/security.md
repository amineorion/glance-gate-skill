# Security playbook

The job: every image glance-gate ships is non-root, shell-less, distroless-or-scratch, and free of fixable CRITICAL CVEs.

## Operating principles

1. **Scan before, scan after, compare.** No baseline → you don't know if you helped or hurt.
2. **Fix what's safe; document what isn't.** Patch-version bumps and base-image refreshes are autonomous. Major version bumps are user-action.
3. **Hardening beats patching.** Switching to distroless removes 80% of OS-level CVEs without touching a dependency.
4. **Never claim "secure" while unfixed reachable CRITICALs remain.** Either fix, or flag for user action.

## Phase 1 — Baseline scan

If a Dockerfile already exists in the repo:

```bash
docker build -t glance-gate-baseline -f Dockerfile .
./scripts/scan-cves.sh glance-gate-baseline scan-baseline.txt
```

Record: critical / high / medium / low counts, and whether the baseline ran as root with a shell present.

If no Dockerfile exists, skip — there is no baseline to compare against. Don't fabricate one.

## Phase 2 — Dependency audit (language-delegated)

| Language | Tool |
|---|---|
| JavaScript / TypeScript | `npm audit --omit=dev` (or `pnpm audit --prod`, `yarn npm audit`, `bun audit`) |
| Python | `pip-audit` |
| Go | `govulncheck ./...` |
| Ruby | `bundler-audit` |
| Java | OWASP `dependency-check` |

Record findings under `security.dependencies` in the final report.

## Phase 3 — Optimized scan

After every Dockerfile iteration:

```bash
./scripts/scan-cves.sh glance-gate-try-N scan-tryN.txt
```

## Mandatory hardening checklist

Every final image must satisfy:

| Check | Requirement |
|---|---|
| Non-root user | `USER <uid>` with uid ≥ 1000; never omit |
| No shell | No `/bin/sh`, `/bin/bash`, `busybox sh` in final stage |
| Distroless / scratch | Final stage uses `gcr.io/distroless/*` or `FROM scratch` unless stack requires otherwise |
| Minimal binaries | No compilers, no package managers, no debuggers in final |
| CA certs | `/etc/ssl/certs/ca-certificates.crt` present if app makes HTTPS calls |
| Exec-form CMD | `CMD ["node", "server.js"]`, not `CMD node server.js` |
| Pinned base | Specific minor version, never `:latest` |

## Fix policy

### You CAN fix autonomously

- Patch-version bumps (`1.2.3 → 1.2.4`)
- Base image minor/patch refresh (`alpine:3.18.4 → alpine:3.18.5`)
- Switching to a stricter base (`slim → distroless`)
- Removing packages not used at runtime
- Applying hardening (non-root, exec-form CMD, capability drop)

### You DOCUMENT but DO NOT apply

- Minor version bumps (`1.2.3 → 1.3.0`) — semver-compatible in theory, breaks in practice
- Major bumps (`1.x → 2.x`)
- Application source changes
- Anything that needs reading the app's business logic

For deferred fixes, write to `glance-gate-report.md → user_action_required`:

```yaml
- cve: CVE-2024-XXXX
  severity: HIGH
  package: express
  installed: 4.18.2
  fixed_in: 5.0.0
  reason: requires_major_upgrade
  action: "Upgrade express from 4.x to 5.x and test all routes for breaking changes."
  impact: "Prototype pollution allows arbitrary property injection."
```

## Comparison

After every iteration, compute:

```
delta_critical = baseline.critical - optimized.critical
delta_high     = baseline.high     - optimized.high
```

- `delta > 0` → you helped
- `delta = 0` → neutral, acceptable if other goals met
- `delta < 0` → **you made it worse**; investigate before continuing

New CVEs in the optimized image usually mean the newer base pulled in a freshly-disclosed package — document and decide.

## Anti-patterns

- Ignoring CVEs as "unreachable" without proof (you don't know that)
- Pinning a vulnerable base "because updating breaks tests" — fix the tests
- `npm audit fix --force` — applies major bumps unvetted
- Disabling scans to hit a deadline
- Adding capabilities back without documenting why
