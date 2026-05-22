# Contributing to glance-gate

Thanks for considering a contribution. This skill is a community knowledge base — every overlay, template, and gotcha you add saves someone else hours of swearing at `docker build`.

## What we want most

In order of impact:

1. **Language overlays.** New playbooks under `playbooks/languages/<lang>.md` for stacks we don't cover. Rust, .NET, PHP, Elixir, Deno are top of the wish list.
2. **Real-world templates.** New files under `templates/Dockerfile.<stack>-<base>` with a *measured* expected size in the header comment.
3. **Gotcha PRs.** When the skill produces a broken Dockerfile on a real repo, send the input + output and we'll add the avoidance rule to the matching overlay.
4. **Script portability.** Scripts in `scripts/` should run on bash 3 (macOS default), bash 5 (Linux), and busybox where possible. Patches welcome.

## What we don't want

- Wholesale rewrites of an overlay without numbers. "I changed everything and it feels better" doesn't ship. "I changed everything and 12 of my 14 reference apps got smaller" does.
- Vendor-specific advertising. Templates that pin to a specific paid product as the only option won't merge.
- Linting / formatting nits as standalone PRs. Roll them into a substantive change.

## How to propose a language overlay

Use the existing overlays (`node.md`, `python.md`, `go.md`) as templates. Each must cover:

1. **Detect.** What files in the repo identify this language + framework + package manager?
2. **Strategy selection.** At least one "preferred" strategy with a working Dockerfile, plus fallbacks for common edge cases (native modules, frameworks with weird build steps).
3. **Scorched-earth cleanup.** Concrete `find` / cleanup commands for this language's dependency layout.
4. **Heavyweight offenders.** Three to five named packages that bloat images and how to handle them.
5. **Gotchas.** Three to five real production landmines.

Each section needs numbers. "Smaller" is meaningless. "60–90 MB on distroless vs 280 MB on `node:20`" is shippable.

## How to test an overlay before sending the PR

1. Clone three real public repos that use the target language.
2. For each: load the skill into Claude Code, run "optimize this Dockerfile."
3. Verify the produced Dockerfile builds and the container starts.
4. Record before/after size for each repo in the PR description.

Without those numbers we can't accept the overlay.

## How to test a script change

Scripts are POSIX-ish bash. Verify with `shellcheck` clean and `bash -n` parse on macOS bash 3.2:

```bash
shellcheck scripts/*.sh
for f in scripts/*.sh; do bash -n "$f" || echo "PARSE FAIL: $f"; done
```

## Code of conduct

Be kind. Assume the other party is short on sleep and long on production traffic. PR reviews should focus on the artifact, not the author.

## License of contributions

By submitting a PR you agree your contribution is licensed under Apache 2.0, the same license as this repo.

## Releases

There are no tagged releases yet. The `main` branch is the supported version. If we cut tags later, semver applies to the SKILL.md → playbook schema, not to wording inside playbooks.
