# Go overlay

Pair with `playbooks/optimization.md` and `playbooks/security.md`.

Go is the friendliest language for Tier 0. With static linking and stripped
symbols, a typical web service lands at **8–25 MB total on `FROM scratch`
with zero CVEs** — no glibc, no apk, no shell.

## The three-tier ladder

| Tier | Base | Strategy | Typical size | When |
|---|---|---|---|---|
| **0** | `FROM scratch` | `CGO_ENABLED=0 go build` static binary | **8–25 MB** | Default. Use unless CGO is required. |
| **1** | `gcr.io/distroless/cc-debian12:nonroot` | CGO binary linked against glibc | 25–60 MB | App uses `mattn/go-sqlite3`, CGO-enabled net resolver, or any C dep. |
| **2** | `gcr.io/distroless/static-debian12:nonroot` | static binary + extra runtime files | 12–30 MB | Same as Tier 0 but the app needs `/tmp`, `/etc/passwd`, or `tzdata` and you don't want to assemble a custom scratch rootfs. |

## Detect

- `go.mod` present → Go module. Read the `go 1.X` directive — pin the
  builder to a matching minor (`golang:1.22.5-bookworm` for `go 1.22`).
- `vendor/` directory present → build with `-mod=vendor`.
- Any of `import "C"`, `mattn/go-sqlite3`, `github.com/lib/pq` (with
  cgo), `cosmtrek/air` → CGO required, drop to Tier 1.

### Audit

```bash
grep -rE '^import "C"$' --include='*.go' . | head
go list -e -deps ./... 2>/dev/null | grep -E 'sqlite3|mattn' || echo "no cgo deps"
```

If both return empty: Tier 0. Otherwise Tier 1.

## Tier 0 — static binary on scratch (default)

```dockerfile
FROM golang:1.22.5-bookworm AS builder
WORKDIR /src
ENV CGO_ENABLED=0 GOOS=linux GOFLAGS="-buildvcs=false"
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    go mod download
COPY . .
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    go build \
      -trimpath \
      -ldflags="-s -w -buildid=" \
      -o /out/app ./cmd/server

FROM scratch
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=builder /out/app /app
USER 1000:1000
EXPOSE 8080
ENTRYPOINT ["/app"]
```

### Mandatory build flags

| Flag | Why |
|---|---|
| `CGO_ENABLED=0` | No C runtime → no glibc/musl in binary → `FROM scratch` viable. |
| `-trimpath` | Strips local filesystem paths (reproducibility + smaller). |
| `-ldflags="-s -w"` | Drops symbol table + DWARF (typical 20–30% size cut). |
| `-buildid=` | Removes build ID for byte-for-byte reproducibility. |
| `GOFLAGS="-buildvcs=false"` | Don't embed VCS info (Go ≥1.18 default-embeds). |

## Tier 1 — CGO on distroless/cc

```dockerfile
FROM golang:1.22.5-bookworm AS builder
WORKDIR /src
ENV CGO_ENABLED=1 GOOS=linux
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN go build -ldflags="-s -w" -o /out/app ./cmd/server

FROM gcr.io/distroless/cc-debian12:nonroot
COPY --from=builder /out/app /app
USER 65532:65532
ENTRYPOINT ["/app"]
```

`distroless/cc` ships glibc + minimal C runtime. ~25 MB base overhead.

## Smoke test — required for every tier

```bash
./scripts/smoke-test.sh glance-gate-try-N \
  --probe /healthz=200 \
  --probe /nonexistent=404 \
  --user-check 1000 \
  --sigterm-deadline 5
```

Go binaries are typically very fast to start (< 100 ms) — `--wait 2` is
usually enough. SIGTERM should exit cleanly in < 1s if the app uses
`signal.NotifyContext` / `errgroup.WithContext`.

## Scratch's missing files — what to add per use case

`FROM scratch` ships nothing. If the app needs:

| Need | Add |
|---|---|
| HTTPS outbound calls | `COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt` |
| Non-UTC time zones | `COPY --from=builder /usr/share/zoneinfo /usr/share/zoneinfo` OR `import _ "time/tzdata"` (embeds in binary, +400 KB) |
| `/tmp` writable | Use `distroless/static-debian12` (Tier 2) or COPY an empty chowned dir. |
| `/etc/passwd` resolution | Use numeric `USER 1000:1000` instead of named (`USER appuser` fails on scratch). |
| `nobody` shell | Don't ship one. If your code shells out, you have bigger problems. |

## Vulnerability scanning

```bash
go install golang.org/x/vuln/cmd/govulncheck@latest
govulncheck ./...
```

`govulncheck` is reachability-aware — only flags CVEs you actually hit.
Stronger signal than generic dep scanners for Go.

## Heavyweight offenders

- `github.com/aws/aws-sdk-go` v1 → ~30 MB binary contribution. Use
  `aws-sdk-go-v2` modular packages.
- `k8s.io/client-go` → huge dependency tree. Split your binary by
  command (`server`, `migrate`, `worker`) if you only need a subset.
- `embed.FS` of large static assets → visible in binary. Serve from
  object storage if > 50 MB.

## The SQLite trap — `mattn/go-sqlite3` blocks Tier 0

`gorm.io/driver/sqlite` transitively pulls
`github.com/mattn/go-sqlite3`, which is a **CGO binding**. With
`CGO_ENABLED=0` the build link-errors out at `golang.org/x/crypto/sha3`
even before the sqlite driver is touched. With `CGO_ENABLED=1` you
ship glibc-or-musl dependencies — Tier 1 (distroless/cc) is the
floor.

**Unlock — switch to `modernc.org/sqlite`** (pure-Go, no CGO):

```go
// before
import _ "gorm.io/driver/sqlite"
// after
import _ "github.com/glebarez/sqlite" // gorm wrapper around modernc.org/sqlite
```

Then `CGO_ENABLED=0` builds cleanly → `FROM scratch` → typical drop
from ~13 MB (Tier 1) to ~6 MB (Tier 0).

The audit should grep for `mattn/go-sqlite3` in `go.sum`; if present,
log it as user_action_required and ship Tier 1.

## Gotchas

- **`scratch` has no `/tmp`.** If the app writes temp files, either use
  `distroless/static` or `t.TempDir()` won't work — use an in-memory
  approach.
- **No CA certs by default.** Always `COPY --from=builder
  /etc/ssl/certs/ca-certificates.crt ...` if the app makes HTTPS calls.
- **No `/etc/passwd`** — numeric `USER 1000:1000` works; named won't.
- **No shell** — `HEALTHCHECK CMD curl ...` fails. Use Kubernetes
  liveness probes over HTTP, or a tiny static healthcheck binary.
- **Time zones** — import `_ "time/tzdata"` if the app uses non-UTC
  zones, or COPY `/usr/share/zoneinfo` from the builder.
