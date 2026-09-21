# Project memory

Context that is not recoverable from the code or the git log: decisions, why they went that way, what
was tried and rejected, and the data gotchas that cost real time. Read this before changing the stage
model, the filters, or anything that touches a number.

---

## What this is

A CLI that answers one question: **where do PRs wait?** Four stages, anchored on ready-for-review, from
GitHub via `gh`. Plain Ruby, stdlib only — no Gemfile, because nothing outside the standard library is
needed (`json`, `erb`, `optparse`, `yaml`, `open3`). Ruby on the machine it was built on is 2.6.10, so
no `filter_map`, no endless methods, no `Hash#except`.

Two commands and a generated page: `sync` fetches and persists raw JSON, `report` recomputes from raw
without touching the network, and every run writes `data/computed/dashboard.html`.

The split between raw and computed is the point. Stage definitions changed four times during the build
and not once required a re-fetch.

---

## The invariant

`pickup + review + merge_wait == total`, per PR, **on both clocks**, asserted in the test suite and
again on every real run before anything is printed. A violation aborts the run.

It is the whole defence. Every missing-anchor and clamping bug found during the build was caught by it
first. Do not weaken it to make a new stage definition fit — if segments stop summing, the definition
is wrong, not the assertion.

---

## Decisions, and why

### Anchor on ready-for-review, not PR creation
PRs opened as drafts otherwise report near-zero pickup. Ready comes from the issue timeline
(`ReadyForReviewEvent`, via GraphQL); for PRs never drafted, ready == created and nothing changes. The
**last** ready event wins, not the first — a PR flipped back to draft and re-readied starts its clock
again.

### Working hours, not wall clock — Sunday–Thursday, 09:00–18:00, Amman
This was the single biggest correction to the numbers. Overnight and weekend gaps were inflating pickup
**2–3×**: 5.8h wall became 2.7h at work, and one week's bottleneck flipped from pickup to review once
the nights came out. A PR ready 18:00 and reviewed 09:10 next morning is 15.2h on the wall and 10
minutes at work.

Amman is fixed UTC+3 year-round (no DST since 2022), so a hardcoded offset is correct and no tzdata
lookup is needed. Public holidays are **not** modelled — known gap, would need a calendar source.

Both clocks are derived from **one** set of stage boundaries (`spans` in `Compute.row`) specifically so
they cannot drift apart. Wall-clock values survive in `prs.json` as `*_s` beside the `*_bh_s` twins.

### Reviewer response time is per person, not the PR's pickup
`--group-by reviewer` originally showed the PR's pickup for every PR that person reviewed — which is
the time until whoever answered *first* answered, not until *they* did. Useless for "who is the queue".
Rows now carry `responses: {login => {s, bh_s, comments, reviewed, approved, silent}}`, so a person's
median is their own time to first touch.

### Bots are structural, not configurable
`Compute::NEVER_HUMAN`, checked inside `Compute.bot?` so no flag and no config edit can reach past it.
The `--no-exclude-bots` flag was deleted: its only effect was reporting pickup as 0.0h for the entire
repo, which is not a view anyone needs.

### One rule, no flags
Deliberate direction from the owner after flag creep set in. Prefer deleting a switch over adding one.
Flags that exist because a decision was avoided are the smell.

---

## Rejected, with the data that killed it

### Excluding integration / "release branch" PRs — rejected
The theory: PRs merging a long-lived feature branch into `master` are batch merges, not code reviews,
and distort the medians. Detection was built (fetch every branch ever used as a base repo-wide, flag any
PR whose own head branch is in that set) and then measured:

```
rule               n    pickup    review  merge_wait
all              200      5.8h      1.3h        0.3h
leaf-only        188      4.0h      1.1h        0.3h
master-only      157      1.8h      1.2h        0.2h
```

Leaf-only excluded `#951`, `#918`, `#907` — real, genuinely reviewed PRs that happen to be part of a
stack (`#1029 → #951 → #928 → #1019 → #1028`). **A PR stack and an integration branch are
indistinguishable from outside**: both are a branch with PRs merged into them. 89 branches in
`zenhr/zenhr` have been used as a base.

Cost of not excluding: 1.8h of pickup. Cost of excluding: deleting real reviews. Code was reverted.
`--base master` reproduces the mainline view on demand, so nothing was lost.

Also worth recording: **there are no release branches.** No `release/*` in the data; releases go
straight to `master`. What looks like release flow is stacked *feature* branches.

### Per-author metrics — PRD position reversed, deliberately
The PRD said both `--author` and `--reviewer` ship but "output stays local, and no per-author view is
published to a shared channel". When the dashboard was built for non-technical managers, the owner was
asked directly and chose **full flexibility** — author, reviewer and per-person role splits are all in
the shared page.

That is a conscious reversal, not an oversight. The dashboard *is* the shared channel the PRD was
warning about. If someone later asks why named engineers are in a manager-facing file, this is why.

---

## Data gotchas that cost time

### CI bots carry no `is_bot` and no `[bot]` suffix
`coderabbitai` and `github-actions` respond within ~2 minutes of a PR going ready and arrive through
`gh` as plain logins. Unfiltered, **pickup read 0.0h on every PR in the repo**. This is the single most
dangerous failure mode in the tool: it looks like a great number rather than a broken one.

### `gh pr list` does not return review comments
Only **13 of 1007** reviews had a non-empty body, yet 461 were state `COMMENTED`. Review discussion
lives in inline review threads, which `--json reviews` does not include. Real counts come from GraphQL
`reviews { comments { totalCount } }`, added to the same paged query as the timeline. Without it every
comments-per-PR ratio reads 0.00 and looks plausible.

### `gh pr list` has no cursor and 502/504s on large repos
Past roughly 25 PRs with `reviews` and `comments` attached, `zenhr/zenhr` returns
`HTTP 504: We couldn't respond to your request in time`. `Fetch.list_prs` pages backwards through
`created:<=DATE` search windows at 25 per call, dedupes by number, and `Fetch.gh` retries 5xx three
times with backoff. Backfills past a few hundred PRs are slow; this is the reason.

### GitHub teams overlap
`developers` and `zenhr-deployment` are access groups holding half the org. On the first pass
`zenhr-deployment` swallowed 119 of 200 PRs and every squad vanished. `Fetch.teams` writes
**smallest team first** and the lookup takes the first match, so squads beat access groups. Members in
more than one team are reported on stderr. Deleting the access groups from `config/teams.yml` sharpens
the split further.

### Ruby 2.6
`filter_map` and endless method definitions are not available. Both were written and both failed before
being noticed.

---

## Thresholds, and where they live

| Value | Where | Why |
|---|---|---|
| suppress under 10 PRs | `Aggregate::MIN_N`, mirrored in the dashboard | a median of 4 PRs is noise |
| rank reviewers at 5+ PRs | `MIN_REVIEWS` in the dashboard | a 3-sample reviewer topped the ranking at 44.5h |
| tail = slowest 20% | dashboard diagnostics | separates a few bad PRs from a systemic problem |
| 1.3× before calling something "a driver" | dashboard diagnostics | it printed "1.9h vs 1.9h" as a finding before this |
| Sun–Thu, 09:00–18:00 | `Compute::WORK_DAYS`, `DAY_START`, `DAY_END` | Amman work week |

Changing working hours needs a `report`, not a `sync` — it recomputes from raw.

---

## Shape of the data

`data/computed/prs.json` is one flat row per merged PR. Everything downstream — filters, grouping,
rankings, the dashboard — is a predicate or a reduce over that array. There is no query engine and
there should not be one.

`flags[]` carries what happened to a row rather than hiding it: `no_review`, `no_approval`,
`clamped_negative`, `approval_after_merge`, `response_after_merge`, `force_pushed`,
`ready_from_timeline`. `nil` means not applicable and is excluded from aggregates; `0` means a genuine
zero. Never conflate the two — several rules depend on the distinction.

---

## Dashboard

One self-contained HTML file, data embedded, vanilla JS, no CDN, no build step, works offline. A
manager double-clicks it. Deliberately not a server or a hosted app — the PRD lists that as a non-goal
and says adopt Middleware or DevLake instead if it ever becomes a company-wide dependency.

Every figure follows the filters, including the header count. Dropdowns cascade: each offers only what
is still reachable through the other active filters, with per-option counts. Fixed at generate time:
the row set, the team map, and the working-hours definition.

Three series colours are the validated categorical palette, checked against both light and dark
surfaces with the dataviz validator. Do not swap them for arbitrary hex.

---

## Open

- Public holidays are not modelled in the working-hours clock.
- No incremental sync — every `sync` re-fetches the whole window.
- Inline review comment *counts* are fetched, but not their timestamps, so "time to first inline
  comment" is not available.
- Repos in use: `zenhr/zenhr` only so far. `config/ignore.yml` holds the default list.
- Runs are manual. A cron job would publish per-author numbers on a schedule, which is a bigger
  decision than a scheduler.
