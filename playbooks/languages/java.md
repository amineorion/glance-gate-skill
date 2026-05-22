# Java overlay

Pair with `playbooks/optimization.md` and `playbooks/security.md`.

Java has a real floor. With Spring Boot + classpath scanning + reflection,
you're unlikely to get under 80 MB on distroless without native-image.
GraalVM native-image with `--static --libc=musl` is the only real path to
Tier 0 on `FROM scratch`.

## The three-tier ladder

| Tier | Base | Strategy | Typical size | When |
|---|---|---|---|---|
| **0** | `FROM scratch` | GraalVM native-image `--static --libc=musl` | 50–80 MB | App tolerates AOT compilation. Spring Boot 3+ has native-image hints. Linux x86_64 only as of GraalVM 22. |
| **1** | `gcr.io/distroless/java21-debian12:nonroot` | Layered jar (Spring Boot ≥ 2.3) | 120–180 MB | Default. Layered cache makes app-only rebuilds fast. |
| **2** | `gcr.io/distroless/java21-debian12:nonroot` | Fat jar (single uber-jar) | 120–180 MB | Non-Spring-Boot apps, or simpler builds. |

The native-image route trades build time (~5 min) and a non-trivial
reflect-config step for cold-start in ~50 ms and a tiny final image.

## Detect

- `pom.xml` → Maven. Build with `mvn -B -q -DskipTests package`.
- `build.gradle` / `build.gradle.kts` → Gradle. Build with `./gradlew bootJar -x test`.
- Java version from `<java.version>` in `pom.xml` or `sourceCompatibility`
  in Gradle. Pin builder accordingly.
- Look for `spring-boot-starter-parent` ≥ 3.0 → native-image hints
  available.

### Audit

```bash
# Reflection-heavy code that native-image needs hints for.
grep -rE 'Class\.forName|getDeclaredMethod|setAccessible|Proxy\.newProxyInstance' \
  --include='*.java' src/ | head

# JSON polymorphism (Jackson). Each needs @JsonTypeInfo + reflect hints.
grep -rE '@JsonTypeInfo|@JsonSubTypes' --include='*.java' src/ | head

# Service loader pattern.
ls META-INF/services 2>/dev/null
```

## Tier 0 — GraalVM native-image to scratch

Spring Boot 3+:

```dockerfile
FROM ghcr.io/graalvm/native-image-community:21-musl AS builder
WORKDIR /src
COPY . .
RUN ./mvnw -B -Pnative native:compile -DskipTests \
      -Dnative.compile.args="--static --libc=musl"

FROM scratch
COPY --from=builder /src/target/app /app
USER 1000:1000
EXPOSE 8080
ENTRYPOINT ["/app"]
```

Result: 50–80 MB. Startup drops from seconds to ~50 ms. Caveats:
- 5 min build.
- Reflection-heavy code needs `reflect-config.json` hints — Spring Boot
  3 auto-generates many of them.
- Some libraries don't work at all (anything that does dynamic
  classloading at runtime).
- `--libc=musl` requires the `-musl` variant of the GraalVM image
  (Linux x86_64 only as of GraalVM 22).

If `--static --libc=musl` fails, fall back to `--static-nolibc` on
`gcr.io/distroless/base-debian12` (adds glibc — still small,
gives up the musl CVE-class win).

## Tier 1 — Layered jar on distroless (default)

```dockerfile
FROM eclipse-temurin:21-jdk-jammy AS builder
WORKDIR /src
COPY mvnw .mvn ./
COPY pom.xml ./
RUN --mount=type=cache,target=/root/.m2 ./mvnw -B -q dependency:go-offline
COPY src ./src
RUN --mount=type=cache,target=/root/.m2 \
    ./mvnw -B -q -DskipTests package && \
    mkdir -p /unpacked && cd /unpacked && \
    java -Djarmode=layertools -jar /src/target/*.jar extract

FROM gcr.io/distroless/java21-debian12:nonroot AS runtime
WORKDIR /app
COPY --from=builder /unpacked/dependencies/ ./
COPY --from=builder /unpacked/spring-boot-loader/ ./
COPY --from=builder /unpacked/snapshot-dependencies/ ./
COPY --from=builder /unpacked/application/ ./
EXPOSE 8080
ENTRYPOINT ["java", "org.springframework.boot.loader.launch.JarLauncher"]
```

Spring Boot ≥ 2.3 supports layered jars. Builder extracts layers;
runtime stage COPYs them separately so dependency changes don't bust
the application-layer cache.

## Smoke test

```bash
./scripts/smoke-test.sh glance-gate-try-N \
  --with-db postgres \
  --probe /actuator/health=200 \
  --probe /nonexistent=404 \
  --wait 15 \
  --sigterm-deadline 30
```

Spring Boot apps take 5–15s to start (longer on Tier 1, ~50 ms on
Tier 0 native). The `--wait` and `--sigterm-deadline` must be generous
for Tier 1 builds.

## Heavyweight offenders

- Multiple HTTP clients in the same app (Apache HttpClient + OkHttp +
  Spring `RestTemplate`) — pick one.
- `aws-sdk-java` v1 monolith → 80 MB. Switch to v2 service-by-service.
- Tomcat embedded when you don't need a servlet container — Spring
  WebFlux on Netty is smaller.
- Multiple JSON libraries (Jackson + Gson + JSON-B) — pick one.

## Spring Boot 2.x — the CVE cliff

Verified on a Spring Boot 2.6 + DGS GraphQL realworld run: the layered
jar lands at ~144 MB on `distroless/java11-debian11` and Trivy reports
**16 CRITICAL + 75 HIGH**. Most of those are in `spring-security-*`,
`spring-web*`, `tomcat-embed-core`, `protobuf-java`, `jackson-databind`,
and `graphql-java` — three years of patched-in-3.x advisories that
never landed in the 2.x backport stream.

The realistic path:

- **Bump to Spring Boot 3.x + Java 17 or 21.** Clears most of the
  CRITICAL+HIGH count in one PR. Required prerequisite for native-image.
- **Then GraalVM native-image with `--static --libc=musl`.** Drops the
  whole JVM-class CVE footprint plus the ~120 MB JRE — ~50–80 MB
  binary on `FROM scratch`.

Spring Boot 2.x → Tier 1 is the floor; expect ~120–180 MB and a
significant CVE backlog until the version bump lands.

## Gotchas

- **Distroless Java pins the JDK version.** Mismatch = `ClassFormatError`.
  Match exactly: `eclipse-temurin:21-jdk-jammy` builder ↔
  `gcr.io/distroless/java21-debian12` runtime.
- **`-XX:MaxRAMPercentage=75`** is a sensible JVM flag for containers
  (default heap detection is conservative on K8s).
- **Native-image + Spring Boot** needs `spring-boot-starter-parent` ≥
  3.0 and `spring-aot` configured.
- **Reflection-heavy code** (Jackson polymorphism, Hibernate proxies)
  needs `reflect-config.json` for native-image.
- **`distroless/java*-debian12:nonroot`** already runs as uid 65532;
  no explicit `USER` needed.
