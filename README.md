# PR Cycle Time Analyzer

Where PRs actually wait. Weekly median and p75 per stage, per repo, with the dominant stage named.

Plain Ruby (stdlib only — no Gemfile, no Rails). Auth comes from `gh`, so there is no PAT to manage.

## Stage model

Anchored on **ready-for-review**, not PR creation:

| Segment | From | To |
|---|---|---|
| `pickup` | ready for review | first human response (review or comment) |
| `review` | first response | last approval |
| `merge_wait` | last approval | merged |
| `draft` (informational) | PR created | ready for review |

`pickup + review + merge_wait` always equals total cycle time (ready → merged). That invariant is asserted per PR
on every run, not just in the tests — a violation aborts the run rather than printing a wrong number.
`draft` is reported separately and excluded from cycle time.

## Usage

```bash
bin/pr-cycle sync --repo zenhr/zenhr --days 90   # fetch from GitHub, persist raw, report
bin/pr-cycle report --group-by author            # recompute from persisted raw, no network
```

`sync` writes `data/raw/<repo>/<date>.json` and every report recomputes from those files, so stage definitions
can change without re-fetching. Computed rows land in `data/computed/prs.json`; the chart in
`data/computed/report.html`.

### Flags

| Flag | Example |
|---|---|
| `--repo` | `--repo zenhr/zenhr --repo zenhr/mfe-monorepo` |
| `--author` | `--author said-zenhr` |
| `--team` | `--team platform-engineering` (needs `config/teams.yml`) |
| `--reviewer` | `--reviewer diyaa-zen` |
| `--label` | `--label backend` |
| `--base` | `--base main` |
| `--min-size` / `--max-size` | `--max-size 400` (lines changed) |
| `--since` / `--until` | `--since 2026-06-01` |
| `--days` | `--days 365` (window when `--since` is absent; `sync` defaults to 90) |
| `--all` | no time window: fetch every merged PR, report everything on disk |
| `--group-by` | `week` (default), `month`, `quarter`, `year`, `all`, `repo`, `author`, `team`, `reviewer`, `label` |
| `--limit` | PRs fetched per repo (default 500, `0` for no cap) |
| `--no-exclude-bots` | bot filtering is on by default |
| `--out` | HTML output path |
| `--no-table` | skip the slowest-PR table on stdout |

Filters compose with AND, and are independent of `--group-by`.

### Windows

Fetching and bucketing are separate. `sync` needs a window or it walks the whole repo history, so it defaults to
90 days; `report` never truncates what is already on disk unless you ask it to.

```bash
bin/pr-cycle sync --repo zenhr/zenhr --days 365   # a year of raw
bin/pr-cycle sync --repo zenhr/zenhr --all        # every merged PR, ever
bin/pr-cycle report --group-by month              # one row per month
bin/pr-cycle report --group-by quarter
bin/pr-cycle report --group-by year
bin/pr-cycle report --group-by all                # one row, whole dataset
bin/pr-cycle report --since 2026-01-01 --group-by month
```

Calendar buckets come off `merged_at` at report time, so widening from week to year never re-fetches. Wider
buckets are also the fix for the low-weekly-volume problem: a repo with 6 PRs a week has every week suppressed at
`n < 10` but reads fine by month.

### Output

Stdout is a colour-coded table: one row per bucket, median and p75 per stage, a proportional split bar, and the
dominant stage named — followed by the slowest 10 PRs with their per-stage breakdown and flags. Colour follows the
terminal: on when stdout is a TTY, off when piped or when `NO_COLOR` is set (the split bar falls back to `#`/`=`/`.`),
forced on with `FORCE_COLOR=1`.

### Teams

```bash
bin/pr-cycle teams --repo zenhr/zenhr   # write config/teams.yml from the org's GitHub teams
bin/pr-cycle report --group-by team
bin/pr-cycle report --team money-team --group-by month
```

A PR's team is its author's team. `teams.yml` is a plain `team: [logins]` map — edit it, it is not overwritten
until you re-run `teams`.

GitHub teams overlap: access groups like `developers` or `zenhr-deployment` contain half the org and would
otherwise swallow every squad. `teams` writes smallest team first and the lookup takes the first match, so squads
win. Delete the access groups from `teams.yml` and the split gets sharper. Authors matched by more than one team
are reported on stderr.

Team-level is also the grouping to reach for before `--author` — same signal, no per-person surface.

### On `--author`

`--author` turns this into per-person cycle time. Middleware deliberately keeps its metrics team-level for that
reason. Both `--author` and `--reviewer` ship, output stays local, and no per-author view gets published to a
shared channel. This is not performance review input.

## Correctness rules

All of them live in `lib/compute.rb`, which is a pure function (raw JSON → rows: no I/O, no network) and is where
the tests point.

1. Anchored on `ready_for_review` from the issue timeline. For PRs opened non-draft, ready == created.
2. Segments sum to total. Asserted per PR in tests *and* on every real run.
3. Broken review chains fall back so no elapsed time disappears: no approval → `review` runs to merge;
   no review at all → the whole span is `pickup`.
4. Bots excluded before anything is computed. GitHub Apps often appear without an `is_bot` flag and without the
   `[bot]` suffix (`coderabbitai`, `github-actions`), so `config/ignore.yml` carries an explicit deny-list.
5. Events after merge (approval-after-merge, post-close review) are dropped rather than allowed to go negative.
   Genuinely impossible spans (clock skew) clamp to `nil`, are flagged `clamped_negative`, counted, and reported.
6. `nil` means not applicable and is excluded from aggregates. `0` means a genuine zero. Never conflated.
7. Open and closed-unmerged PRs excluded.
8. Buckets under 10 PRs print `n=X (suppressed)` instead of a median.
9. Parked PRs are excluded by number via `config/ignore.yml`.

## Config

`config/ignore.yml` holds the default repo list, the per-repo PR ignore-list, and extra bot logins.

## Tests

```bash
ruby test/test_compute.rb
```

Fixtures in `test/fixtures/raw.json` cover each edge case: draft PR, no-review merge, review-without-approval,
bot-only review, approval-after-merge, force-pushed PR, clock skew, open PR, ignored PR.

## Answers to the PRD's open questions

- **Repos in v1** — whatever `--repo` names; `config/ignore.yml` holds the default list, currently `zenhr/zenhr`.
- **Backfill window** — 90 days, via `--days` (override with `--since`).
- **Cron or manual** — manual. A GitHub Action would publish per-author numbers into a shared place, which is
  exactly what the filtering section rules out for v1.

## Known limits

- `gh pr list` has no cursor and 502/504s on large repos past ~25 PRs when reviews and comments are attached, so
  the fetcher pages backwards through `created:` date windows and retries 5xx. Backfills beyond a few hundred PRs
  are slow.
- No incremental sync: each `sync` re-fetches the whole window.
