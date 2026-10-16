# Plans

Every plan for this repo lives here and is committed with the code it describes. Work beyond what Jordan has approved
is written into a plan first and waits for his go. Plans are kept as a graph with
[plangraph](https://github.com/jordanromines-jpg/plugin-plangraph): every step, decision, gate, risk and check is a
node in `plans/graph/`, and the tables in the plan documents are generated from it.

| Path | What it is |
|---|---|
| `plans/README.md` | This file: how plans are written and moved, and the index below (generated) |
| `plans/CHANGELOG.md` | One line per change to any plan, newest first, in the same commit as the change |
| `plans/graph/` | The nodes, one JSON file each. Changed only with `plangraph` (a hook refuses hand edits) |
| `plans/plangraph.json` | The sections every plan must have, and the line limit |
| `plans/archive/` | Plans that are done, superseded or dropped |

## Roadmap

What comes now, next and later, derived from the plans and what each waits on.

<!-- graph: roadmap -->
| Column | Plan | Title | State | Waits on | Work done | Hours (est) |
|---|---|---|---|---|---|---|
| Now | P-1 | [Tether as a download that updates itself](2026-10-15-downloadable-release.md) | in progress | — | 3/20 | 28.75 |
| Now | P-3 | [An API so Claude can control Macs through Tether](2026-10-15-claude-api.md) | approved | — | 0/8 | 16.75 |
<!-- /graph -->

## Plans

<!-- graph: index -->
| Plan | Title | State | Work done | Next | Waiting on Jordan |
|---|---|---|---|---|---|
| P-3 | [An API so Claude can control Macs through Tether](2026-10-15-claude-api.md) | approved | 0/8 | — | — |
| P-2 | Inbox | inbox | 0/0 | — | — |
| P-1 | [Tether as a download that updates itself](2026-10-15-downloadable-release.md) | in progress | 3/20 | S-8 | 2 |
<!-- /graph -->

## How we work with Jordan

From how the web-agent sessions work (`plans/reference/how-we-work.md` there, Jordan, 11 Oct 2026: "I want to be able
to replicate this in the future for a new session").

- **One voice.** One session talks to Jordan. What other sessions or agents find reaches him rewritten, only what
  matters.
- **Keyed tables with a recommendation.** Every status, ask or option list is a table he can answer by key, each row
  with "My rec" (`plangraph asks` prints what waits on him). He answers "yes", "all rec" or by key; his exact words
  are recorded against each key (`plangraph answer D-4,G-2 --quote "<his words>"`, `--rec` for "all rec").
- **Status is a table of pull requests with their keys under them.** Short when asked: what's done, what's left, what
  waits on him, risks. Times in the local clock.
- **Gates are his.** Never answer or default a gate for him; record only his words and evidenced states.
- **New work waits for his go.** Work beyond what he approved is written into the plan first, and found work is
  proposed (`plangraph add … --propose`); adding detail to an idea isn't agreement.
- **Files first.** Before building, say which files a step touches: one editor per file at a time.
- **Mistakes, said plainly.** What went wrong, what it touched, the fix, the rule learned.
- **No agents unless he asks.** Parallel work is sessions he starts, not subagents.

## One file per plan

`plans/YYYY-MM-DD-short-name.md`, dated the day the plan starts. A plan that grows keeps its file; a new direction
gets a new file and, if it replaces an old plan, a `supersedes` edge to it.

## What a plan says

Every plan has these sections, in this order. A section that does not apply says "None." in one line; it is not left
out. Prose (what started it, Why, Design, what it does NOT do, Results) is written by hand; every table is a generated
block that `plangraph render` rebuilds from the graph, so it can't drift.

```markdown
# <Name>

<!-- graph: status P-n -->
<!-- /graph -->

What started it: Jordan's words, dated. Where the plan came from, and what it replaces or carries over.

## Why
The problem, with the evidence (runs, numbers, what was tested, what was measured and what was not).

## Design
The smallest change that fixes the root cause, in plain words. Name each new or changed file once.

## What this does NOT do
The nearby things deliberately left out.

## Requirements
<!-- graph: reqs P-n -->
<!-- /graph -->

## Decisions
<!-- graph: decisions P-n -->
<!-- /graph -->

## Pull requests and keys
<!-- graph: steps P-n -->
<!-- /graph -->

## Gates that need Jordan
<!-- graph: gates P-n -->
<!-- /graph -->

## Risks
<!-- graph: risks P-n -->
<!-- /graph -->

## Verification
<!-- graph: checks P-n -->
<!-- /graph -->

## Build log
<!-- graph: log P-n -->
<!-- /graph -->

## Results
What happened: pull requests and commits, before/after numbers, what's left.
```

## Keys

Keys are a kind and a number, one key one thing, never reused: `P` plan · `M` milestone · `PR` pull request · `S` step
· `D` decision · `G` gate · `Q` open question · `R` risk · `V` verification · `T` Jordan's test · `REQ` requirement ·
`L-<name>` lane. Jordan answers by key ("D-4: yes"). A renamed key stays as an alias; old keys from earlier plans and
release numbers are aliases too.

- Every step belongs to exactly one pull request (or milestone), and every pull request to one plan.
- Waiting is an edge, not a sentence: `plangraph link S-7 depends_on S-3`. What is ready, blocked or late, and the
  critical path, are worked out from the edges.

## Time bounds and self-checks (every plan)

- **Every step has an estimate and a stop point**: 1.5 times the estimate. `plangraph status` lists what is past it.
- **Every step has a self-check** (`done_when`, and `command` when one command proves it). A step is done only with
  evidence: `plangraph done S-7 --evidence "…" --commit <sha>`. Hours used are measured from claim to done (summed
  over every claim); `--used 1.5` overrides them when the clock is wrong, and the measured time is kept beside it.
- **Over the stop point**: stop, note why (`plangraph note`), re-estimate it and everything after it; go on only if the
  total stays within 20 % of the plan's, otherwise ask Jordan. At 2 times: always stop and ask.
- **Resume from the graph.** `plangraph status` names what is being done and what is next. Nothing lives only in a
  chat.

## How a plan moves

| Stage | What changes |
|---|---|
| Draft | Written in plan mode or with `/plangraph:plan`; its nodes are in the graph, status draft |
| Awaiting approval | Shown to Jordan with its decisions, each with a recommendation first |
| Approved | `plangraph approve P-n --quote "<his words>"`; only his own words count, and a hook checks them |
| In progress | Steps claimed and done with evidence; the build log is the nodes' history |
| Built / done | All steps done / and all checks done. The status line says so, because it is generated |
| Parked, dropped, superseded | `plangraph park|drop P-n --why …`, or a newer plan `supersedes` it; `git mv` to `archive/` |
