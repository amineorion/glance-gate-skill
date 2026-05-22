# Python overlay

Pair with `playbooks/optimization.md` and `playbooks/security.md`.

## The three-tier ladder

| Tier | Base | Strategy | Typical size | When |
|---|---|---|---|---|
| **0** | `FROM scratch` | PyInstaller / Nuitka standalone binary | 30–80 MB | Rare. Pure-Python or wheels-only deps without C extensions that PyInstaller can hoist. |
| **1** | `python:3.X-alpine` (musl) | `pip install` + scorched-earth | 80–180 MB | Default. Drops debian glibc CVEs. Works if every native wheel has musllinux builds. |
| **2** | `gcr.io/distroless/python3-debian12:nonroot` | `pip install --target=/install` + scorched-earth | 100–180 MB | Fallback when an alpine musl wheel is missing. |
| **3** | `python:3.X-slim` | full deps tree | 250–600 MB | When neither slim-distroless nor alpine work (rare — usually a build-from-source dep). |

The musl-first preference is new and important: alpine drops the
"Debian won't patch this glibc CVE in bookworm" class entirely. Test
that every native wheel resolves a `cp3X-musllinux_*.whl` build first
(`pip download --platform musllinux_1_2_x86_64 ...` to dry-run).

## Detect

### Package manager

| File | Manager | Install command |
|---|---|---|
| `poetry.lock` | poetry | `poetry export -f requirements.txt --without-hashes \| pip install -r /dev/stdin` |
| `Pipfile.lock` | pipenv | `pipenv install --deploy --system` |
| `requirements.txt` | pip | `pip install --no-cache-dir -r requirements.txt` |
| `pdm.lock` | pdm | `pdm install --prod` |
| `uv.lock` | uv | `uv sync --frozen --no-dev` |

### Framework

| Framework | Signal | Notes |
|---|---|---|
| FastAPI | `fastapi` in deps | Pairs well with `uvicorn`. Tier 1 viable. |
| Django | `django` + `manage.py` | Needs static files + DB driver. Tier 2 typical (Pillow + psycopg2 + lxml). |
| Flask | `flask` in deps | Smallest of the three. Tier 1 viable. |
| Streamlit | `streamlit` in deps | Heavy — accept 250 MB+. Tier 3. |

### Native / C-extension deps — block scratch, sometimes block alpine

`Pillow`, `lxml`, `psycopg2` (use `psycopg2-binary` or `psycopg[binary]`),
`cryptography`, `numpy`, `pandas`, `pyarrow`, `tensorflow`, `torch`.

**The musllinux-wheel check** decides Tier 1 vs Tier 2:

```bash
pip download --platform musllinux_1_2_x86_64 --only-binary=:all: \
  --dest /tmp/wheels --no-deps -r requirements.txt
ls /tmp/wheels  # confirm every dep got a wheel
```

If any dep falls back to source distribution → Tier 2 (slim-debian or
distroless/python3-debian12).

### Audit

```bash
# Find imports the bundler / freezer can't see (lazy imports).
grep -rEn "(importlib\.import_module|__import__\(|importlib\.metadata)" \
  --include='*.py' src/ app/ 2>/dev/null | head

# Find eval / exec.
grep -rEn '\b(eval|exec)\(' --include='*.py' src/ app/ 2>/dev/null | head
```

If `importlib.metadata.version(...)` is called on bundled packages, the
bundler must keep `.dist-info/METADATA` — DO NOT scorched-earth
`.dist-info` directories.

## Tier 1 — alpine multi-stage (preferred default)

```dockerfile
FROM python:3.12-alpine AS builder
WORKDIR /app
ENV PYTHONDONTWRITEBYTECODE=1 PIP_DISABLE_PIP_VERSION_CHECK=1 PIP_NO_CACHE_DIR=1
# build-base needed only if a dep falls through to sdist.
RUN apk add --no-cache build-base linux-headers
COPY requirements.txt ./
RUN pip install --target=/install -r requirements.txt

# Scorched-earth — careful with .dist-info if your app introspects metadata.
RUN find /install -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true && \
    find /install -type d -name "tests"       -exec rm -rf {} + 2>/dev/null || true && \
    find /install -type d -name "test"        -exec rm -rf {} + 2>/dev/null || true && \
    find /install -type f -name "*.pyc"       -delete && \
    find /install -type f -name "*.pyo"       -delete && \
    find /install -type d -name "*.egg-info"  -exec rm -rf {} +

FROM python:3.12-alpine AS runtime
WORKDIR /app
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=/app/site-packages
RUN addgroup -g 1000 app && \
    adduser -u 1000 -G app -s /sbin/nologin -D app
COPY --from=builder --chown=1000:1000 /install /app/site-packages
COPY --chown=1000:1000 . .
USER 1000:1000
EXPOSE 8000
CMD ["python", "-m", "uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
```

Result: 80–150 MB for FastAPI/Flask without numpy.

## Tier 2 — distroless multi-stage

```dockerfile
FROM python:3.12-slim AS builder
WORKDIR /app
ENV PYTHONDONTWRITEBYTECODE=1 PIP_DISABLE_PIP_VERSION_CHECK=1 PIP_NO_CACHE_DIR=1
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential && rm -rf /var/lib/apt/lists/*
COPY requirements.txt ./
RUN pip install --target=/install -r requirements.txt
# Same scorched-earth as Tier 1.

FROM gcr.io/distroless/python3-debian12:nonroot AS runtime
WORKDIR /app
COPY --from=builder /install /app/site-packages
COPY . .
ENV PYTHONPATH=/app/site-packages PYTHONDONTWRITEBYTECODE=1
EXPOSE 8000
CMD ["main.py"]
```

Inherits the same debian glibc/libssl3 CVEs documented in
`playbooks/optimization.md` § musl-vs-glibc. Prefer Tier 1 when wheels
resolve.

## Scorched-earth cleanup

```bash
find /install -type d -name "__pycache__" -exec rm -rf {} +
find /install -type d -name "tests"       -exec rm -rf {} +
find /install -type d -name "test"        -exec rm -rf {} +
find /install -type f -name "*.pyc"       -delete
find /install -type f -name "*.pyo"       -delete
find /install -type d -name "*.egg-info"  -exec rm -rf {} +
# DO NOT touch .dist-info — importlib.metadata.version() needs METADATA.
```

## Smoke test

```bash
./scripts/smoke-test.sh glance-gate-try-N \
  --with-db postgres \
  --probe /healthz=200 \
  --user-check 1000 \
  --sigterm-deadline 10
```

`--with-db postgres` injects `DATABASE_URL`. For Mongo apps, `--with-db
mongo` injects `DATABASE`/`MONGO_URL`/`MONGODB_URI`. Most python apps
read one of these — adapt the env name with `--env DATABASE_URL=...`
if not.

## Heavyweight offenders

- `tensorflow` → 500 MB+. Use `tensorflow-cpu` or split inference to a
  separate service.
- `torch` → 800 MB+. Use `torch-cpu` wheel.
- `pandas` + `numpy` together → 150 MB minimum. Consider `polars`.
- `boto3` → 90 MB. Use only needed services.

## Gotchas

- **`pip install` writes to `~/.cache/pip`** — set `PIP_NO_CACHE_DIR=1`
  or use `--no-cache-dir`.
- **`__pycache__` regenerates at runtime.** Set `PYTHONDONTWRITEBYTECODE=1`
  to skip.
- **Distroless Python expects the script as CMD**, not `python script.py`.
  The entrypoint is already `python3`.
- **`cryptography` needs `libffi` + `libssl`.** Slim has both;
  alpine needs `libffi-dev openssl-dev` to rebuild — usually the
  precompiled musllinux wheel covers it.
- **Django needs `collectstatic`** + a static file server (whitenoise).
  Don't shove nginx in the runtime image.
- **`importlib.metadata`** + scorched-earth `.dist-info` = `PackageNotFoundError`
  at runtime. Keep `.dist-info` if any dep introspects.
