# Ruby overlay

Pair with `playbooks/optimization.md` and `playbooks/security.md`.

Ruby has practical limits — no production-grade Tier 0 compiler exists.
The interpreter floor + gem footprint sits around 70 MB on alpine even
before the app. Realistic targets: 70–130 MB for Rails API on
`ruby:slim-alpine`, 120–180 MB on `ruby:slim-bookworm`.

## The three-tier ladder

| Tier | Base | Strategy | Typical size | When |
|---|---|---|---|---|
| **0** | — | — | — | Not reachable in practice. (mruby/CRuby static-link experiments exist but break most gems.) |
| **1** | `ruby:3.X-alpine` (musl) | bundler deploy + scorched-earth | **70–130 MB** | Default. Drops debian glibc CVEs. Works if every native gem has musl-compat prebuilds. |
| **2** | `ruby:3.X-slim-bookworm` | bundler deploy + scorched-earth | 120–180 MB | Fallback when a native gem can't compile on musl. |

The alpine-first preference is the same musl-vs-glibc rule from
`optimization.md`. Confirm every native gem has musl support first
(test build locally on `ruby:3.X-alpine`).

## Detect

- `Gemfile` + `Gemfile.lock` present → bundler. Always install with
  `bundle install --frozen --without development test`.
- Ruby version from `.ruby-version` or `Gemfile`'s `ruby "3.X.X"`.
  Pin builder accordingly.

### Framework

| Framework | Signal | Notes |
|---|---|---|
| Rails | `rails` in Gemfile + `config/application.rb` | Needs `assets:precompile`, often a JS runtime in builder |
| Sinatra | `sinatra` in Gemfile | Tiny — fits on slim cleanly |
| Roda | `roda` in Gemfile | Smaller than Sinatra |
| Hanami | `hanami` | Mid-size, treat like Rails |

### Native gem hot spots — block alpine sometimes

`nokogiri` (ships precompiled in 1.13+ for many platforms — use `bundle
config set force_ruby_platform false`), `pg`, `mysql2`, `sqlite3`,
`bcrypt`, `oj`. Most have musl builds in recent versions.

### Audit

```bash
# Check every native gem has a precompiled platform binary.
bundle config set --local force_ruby_platform false
bundle install --platform x86_64-linux-musl --dry-run 2>&1 | grep -E "(installing|building)" | head

# eval / dynamic require — bundling-blockers.
grep -rE '\b(eval|require)\(' --include='*.rb' app/ lib/ | head
```

## Tier 1 — alpine multi-stage (preferred)

```dockerfile
FROM ruby:3.3.1-alpine AS builder
WORKDIR /app
ENV BUNDLE_DEPLOYMENT=1 BUNDLE_WITHOUT="development:test" BUNDLE_PATH="vendor/bundle"

# build-base + dev libs only for the install step (not shipped to runtime).
RUN apk add --no-cache build-base postgresql-dev yaml-dev

COPY Gemfile Gemfile.lock ./
RUN bundle config set --local force_ruby_platform false && \
    bundle install --jobs 4 && \
    find vendor/bundle -type d \( -name test -o -name spec -o -name doc -o -name examples \) \
      -exec rm -rf {} + 2>/dev/null || true && \
    find vendor/bundle -type f \( -name "*.md" -o -name "*.c" -o -name "*.h" -o -name "*.o" \) \
      -delete

COPY . .
RUN bundle exec bootsnap precompile --gemfile app/ lib/ 2>/dev/null || true
RUN if [ -f bin/rails ]; then \
      SECRET_KEY_BASE=dummy ./bin/rails assets:precompile 2>/dev/null || true; \
    fi

FROM ruby:3.3.1-alpine AS runtime
WORKDIR /app
ENV BUNDLE_DEPLOYMENT=1 BUNDLE_WITHOUT="development:test" BUNDLE_PATH="vendor/bundle" \
    RAILS_ENV=production RAILS_LOG_TO_STDOUT=1 RAILS_SERVE_STATIC_FILES=1

# Runtime native libs (no -dev).
RUN apk add --no-cache postgresql-client yaml tzdata && \
    addgroup -g 1000 app && \
    adduser -u 1000 -G app -s /sbin/nologin -D app

COPY --from=builder --chown=1000:1000 /app /app
USER 1000:1000
EXPOSE 3000
CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]
```

Result: 70–130 MB Rails API on alpine.

## Tier 2 — slim-bookworm fallback

```dockerfile
FROM ruby:3.3.1-slim-bookworm AS builder
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential libpq-dev libyaml-dev && rm -rf /var/lib/apt/lists/*
# ...same bundle install + scorched-earth as Tier 1...

FROM ruby:3.3.1-slim-bookworm AS runtime
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends \
      libpq5 libyaml-0-2 tzdata && rm -rf /var/lib/apt/lists/* && \
    useradd -u 1000 -m -s /bin/sh app
COPY --from=builder --chown=app:app /app /app
USER app
CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]
```

## Scorched-earth cleanup

```bash
# After bundle install
find vendor/bundle -type d \( -name test -o -name spec -o -name doc -o -name examples \) \
  -exec rm -rf {} + 2>/dev/null || true
find vendor/bundle -type f -name "*.md" -delete
find vendor/bundle -type f -name "CHANGELOG*" -delete
find vendor/bundle -type f -name "*.c" -delete
find vendor/bundle -type f -name "*.h" -delete
find vendor/bundle -type f -name "*.o" -delete
```

Be careful with `*.c` / `*.h` if any gem performs runtime native
compilation (rare in production).

## Smoke test

```bash
./scripts/smoke-test.sh glance-gate-try-N \
  --with-db postgres \
  --probe /up=200 \
  --probe /nonexistent=404 \
  --wait 12 \
  --sigterm-deadline 30
```

Rails boot takes 5–15 s. Puma's `--prune-bundler` mode forks workers
slowly; bump `--wait` if smoke times out.

## Vulnerability scanning

```bash
gem install bundler-audit
bundle-audit check --update
```

## Heavyweight offenders

- `nokogiri` — ~25 MB. Unavoidable for many Rails apps. Use precompiled
  platform binaries (alpine musl supported since 1.16).
- `aws-sdk` umbrella gem — pulls all services. Use `aws-sdk-s3`,
  `aws-sdk-sqs` individually.
- `selenium-webdriver` in production — test-only dep, often leaks
  into the main Gemfile group.
- `rspec`, `factory_bot`, `capybara` in production group — move to
  `:development, :test`.

## Stale Gemfile.lock — detect early, fail fast

Repos with a `Gemfile.lock` older than ~2018 are likely **unbuildable
on any modern Ruby**. The smoking gun is a `json 1.x` gem pin whose C
extension references pre-Ruby-2.4 internals:

```
generator.c:861:25: error: 'rb_cFixnum' undeclared (first use in this function);
generator.c:863:25: error: 'rb_cBignum' undeclared (first use in this function);
```

`rb_cFixnum` / `rb_cBignum` were unified into `rb_cInteger` in Ruby 2.4
(2016). The pinned `json 1.x` gem can't build against Ruby 2.7+ headers,
and `ruby:2.4-alpine` / earlier images aren't on Docker Hub anymore
(EOL'd 2020).

**Audit fingerprint:** grep `Gemfile.lock` for:

```
json (1.
```

If matched, **don't burn a 5-min build cycle**. Emit `user_action_required`:

> The Gemfile.lock is from a pre-Ruby-2.4 era. To make this repo
> deployable: (1) bump Rails to a maintained line (7.1+), (2) regenerate
> Gemfile.lock with Bundler 2.5+, (3) add `.ruby-version` pinning a
> maintained Ruby (3.3.x). Then re-run glance-gate.

Verified on the 2016 rails-realworld-example-app (`rails '4.2.6'` +
`json 1.x`): naive baseline fails identically to the optimized Tier 2
attempt — the bottleneck is dep-ecosystem age, not the Dockerfile.

## Gotchas

- **Bundler caches gems in `~/.bundle` AND `vendor/bundle`** depending
  on config — pick one (`vendor/bundle` for reproducibility).
- **Rails 7+ uses `propshaft` or `sprockets`.** `propshaft` doesn't
  need a JS toolchain at runtime.
- **`bootsnap` precompilation** must happen at build time, not runtime
  — first-request latency otherwise.
- **`RAILS_LOG_TO_STDOUT=1`** is what containerized Rails apps want;
  otherwise logs go to `log/production.log` inside the image.
- **`force_ruby_platform false`** is required for native gems to use
  precompiled binaries — otherwise bundler builds from source and you
  need `-dev` packages in the runtime image.
