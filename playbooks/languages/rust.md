# Rust overlay

Pair with `playbooks/optimization.md` and `playbooks/security.md`.

Rust, like Go, is a Tier-0 native target. With the `*-unknown-linux-musl`
toolchain a typical web service ships at 5–25 MB on `FROM scratch` with
zero CVEs.

## The three-tier ladder

| Tier | Base | Strategy | Typical size | When |
|---|---|---|---|---|
| **0** | `FROM scratch` | `cargo build --release --target *-unknown-linux-musl` | **5–25 MB** | Default. No C deps that require dynamic linking. |
| **1** | `gcr.io/distroless/cc-debian12:nonroot` | `cargo build --release` against glibc | 25–60 MB | Dynamically linked against system libraries (rare — usually deliberate). |

The Tier 0 musl variant is almost always preferable for the same
reason as the Node alpine route: no debian glibc CVEs in the runtime
image.

## Detect

- `Cargo.toml` present → Cargo project. Workspaces live in
  `[workspace] members = ["..."]`.
- `rust-toolchain.toml` / `rust-toolchain` → pin the builder to that
  version.
- `[dependencies]` with `*-sys` crates → likely needs a system C
  library. Examples: `openssl-sys`, `libpq-sys`, `sqlite3-sys`. With
  musl + `rustls` instead of openssl-sys, Tier 0 stays reachable.

### Audit

```bash
# C-binding crates that often force dynamic linking.
grep -E '^(openssl|openssl-sys|libpq-sys|sqlite3-sys|mysqlclient-sys) ' \
  Cargo.lock 2>/dev/null | head

# Workspace size.
find . -maxdepth 3 -name Cargo.toml -not -path './target/*' | wc -l
```

If `openssl-sys` appears: either swap to `rustls` (no C dep) or accept
Tier 1.

## Tier 0 — static musl binary on scratch (default)

```dockerfile
FROM rust:1.83-bookworm AS builder
WORKDIR /src

ARG TARGETARCH=arm64
RUN apt-get update && apt-get install -y --no-install-recommends \
      musl-tools && \
    rm -rf /var/lib/apt/lists/* && \
    if [ "$TARGETARCH" = "amd64" ]; then \
      TARGET=x86_64-unknown-linux-musl; \
    else \
      TARGET=aarch64-unknown-linux-musl; \
    fi && \
    rustup target add "$TARGET" && \
    echo "$TARGET" > /tmp/target

# Cache deps separately from source.
COPY Cargo.toml Cargo.lock ./
RUN mkdir src && echo 'fn main(){}' > src/main.rs && \
    cargo build --release --target "$(cat /tmp/target)" && \
    rm -rf src target/*/release/deps/<your-bin-name>-*

COPY . .
RUN cargo build --release --target "$(cat /tmp/target)" && \
    cp "target/$(cat /tmp/target)/release/<your-bin-name>" /out/app && \
    strip /out/app

FROM scratch
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=builder /out/app /app
USER 1000:1000
EXPOSE 8080
ENTRYPOINT ["/app"]
```

### Mandatory release settings (Cargo.toml)

```toml
[profile.release]
opt-level = 3
lto = "thin"          # or "fat" for smaller, slower-to-build
codegen-units = 1     # smaller binary
strip = true          # since 1.59 — embeds strip into cargo
panic = "abort"       # drops unwinding tables — typically 5-10% smaller
```

`panic = "abort"` is only safe if your app doesn't rely on
`catch_unwind` — most web services don't.

### TLS — use rustls, not openssl

```toml
# Cargo.toml
reqwest = { version = "0.12", default-features = false, features = ["rustls-tls"] }
# avoid: features = ["native-tls"] (pulls openssl-sys)
```

`rustls` keeps the binary purely Rust + assembly — Tier 0 stays
reachable, no `openssl-sys` runtime dep.

### Database drivers

| DB | Tier-0-friendly crate |
|---|---|
| PostgreSQL | `sqlx` with `postgres` feature (no libpq) |
| MySQL | `sqlx` with `mysql` feature |
| SQLite | `rusqlite` with `bundled` feature (vendors SQLite) |
| Mongo | `mongodb` (pure Rust) |
| Redis | `redis` (pure Rust) |

## Tier 1 — distroless/cc fallback

```dockerfile
FROM rust:1.83-bookworm AS builder
WORKDIR /src
COPY Cargo.toml Cargo.lock ./
RUN mkdir src && echo 'fn main(){}' > src/main.rs && \
    cargo build --release && rm -rf src
COPY . .
RUN cargo build --release && \
    cp target/release/<your-bin-name> /out/app && \
    strip /out/app

FROM gcr.io/distroless/cc-debian12:nonroot
COPY --from=builder /out/app /app
USER 65532:65532
ENTRYPOINT ["/app"]
```

Use only when a C-binding crate can't be replaced.

## Smoke test

```bash
./scripts/smoke-test.sh glance-gate-try-N \
  --probe /healthz=200 \
  --probe /nonexistent=404 \
  --user-check 1000 \
  --sigterm-deadline 5
```

Rust binaries usually start in < 100 ms and exit on SIGTERM cleanly if
the app uses `tokio::signal::ctrl_c` + `select!` or `axum::Server::with_graceful_shutdown`.

## Heavyweight offenders

- `tokio` with `full` feature → ~2 MB binary contribution. Enable only
  the features you use.
- `serde` + `serde_json` → ~1 MB. Acceptable.
- Tracing crates (`tracing-subscriber` with all `fmt-tracing`) →
  another ~1 MB. Acceptable.
- Embedded large `include_bytes!()` assets → visible in binary; serve
  from object storage if > 10 MB.

## diesel + libpq — the Tier 0 musl trap

`diesel = { features = ["postgres"] }` links libpq via `pq-sys`. On
alpine 3.22 the build link-errors with:

```
fe-secure-common.c: undefined reference to `pg_inet_net_ntop`
fe-secure-common.c: undefined reference to `pg_strerror_r`
```

Alpine 3.22's `postgresql17-dev` package split moved those symbols out
of the static archive `pq-sys` expects. **Three options**, in order
of preference:

1. **Migrate to `sqlx` or `tokio-postgres`** (pure-Rust, no libpq dep).
   Unlocks `cargo build --target=*-musl` → `FROM scratch`. The cleanest
   Tier 0 path. App-side refactor: connection pool + query macros.
2. **Pin builder to `oven/bun:X.Y-alpine3.20`-equivalent rust image**.
   Alpine 3.20's `postgresql-dev` still bundles the missing symbols.
   Ships, but stuck on a frozen alpine tag with its own CVE drift.
3. **Drop to Tier 1 on `debian:12-slim`** with `apt install libpq5` at
   runtime. Avoids the alpine linker issue entirely at the cost of
   shipping a (minimal) shell + the debian-bookworm libssl3 class.
   distroless/cc looks attractive but the libpq + libgssapi + libldap
   + libgnutls + libsasl transitive closure is whack-a-mole — every
   COPY surfaces another missing .so.

The audit should grep `Cargo.toml` for `diesel.*features.*postgres` and
log a clear user_action_required.

## Gotchas

- **`scratch` has no `/tmp`.** Use `tempfile::tempdir_in("/var/tmp")`
  if you need temp files (and COPY a chowned `/var/tmp` into the
  scratch image), or switch to `distroless/static`.
- **No CA certs** — always COPY `ca-certificates.crt`.
- **`USER` named** doesn't resolve on scratch. Use numeric `USER 1000:1000`.
- **`tokio::time::sleep`** needs the `tokio` feature `time` (enabled
  by default in `full`); without it, you get a runtime panic.
- **`debug_assertions` in release** — Cargo turns these off by default;
  if your app reads `cfg!(debug_assertions)` and ships different code
  in release, test both modes.
