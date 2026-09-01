# Handoff: jcode sub-agent token attribution in Pulse

**Written** 2026-08-28 by the previous session. Every number below was measured on this machine, not estimated. Re-measure before trusting any of it if significant time has passed.

**Scope of this handoff: this feature only.** Earlier work in the originating session (gauge direction, multi-account discovery, pricing table, jcode account attribution) is deliberately NOT part of your task. Some of it is referenced only where it constrains this work. Do not continue, revisit, or "finish" any of it.

---

## What the user asked for, in their words

> "What I want is to make sure that jcode reports all the sub-agents, it doesn't matter if they are with Anthropic accounts or OpenAI accounts, it has to record all sub-agents and put it into the main window in pulse today, this month, input, output, they should be together there because it's like a fast review on token usage, but when I click on analytics and I get that screen then per project I should have like another column so tokens and subagent tokens cost and subagent cost..."

And explicitly, on scope:

> "to me I only care about jcode so just leave Anthropic Claude Code out of the way"

So: **jcode only.** Claude Code's own sub-agents are out of scope, and are in any case impossible (see Appendix A - do not spend time rediscovering this).

## Desired end state

### 1. Panel token card (the fast-review surface)

The existing "Token Usage" card gains sub-agent visibility. Today and This Month rows, with input and output, showing main-session and sub-agent usage **together** on the same card. The user's phrasing was "it's like a fast review on token usage", so this surface stays compact - the full split belongs in analytics, not here. Exact layout is yours to design; the requirement is that sub-agent usage is visible rather than silently folded in.

### 2. Analytics window (Usage Breakdown), per project

The user enumerated the columns they want. Verbatim intent, de-duplicated into a column list:

| Column | Meaning |
|---|---|
| Project | existing |
| Sessions | existing |
| Tokens input | main sessions only |
| Tokens output | main sessions only |
| Tokens total (main) | main sessions only |
| Sub-agent input | child sessions only |
| Sub-agent output | child sessions only |
| Sub-agent total | child sessions only |
| Total tokens | main + sub-agent |
| Cost (main) | main sessions only |
| Cost (sub-agent) | child sessions only |
| Total cost | main + sub-agent |
| Last active | existing |

The user also said "the costs for input, the cost for output" - i.e. cost split by input/output is wanted at least conceptually. **Resolve this with them**: thirteen-plus columns will not fit the current window, and a table nobody can read is worse than one that omits a column. Suggest a sensible default (likely: total cost per bucket, with the input/output cost split available on the drill-down row) and get a decision before building. Do not guess and build the wide version.

---

## Verified facts about the data

All measured 2026-08-28 against `~/.jcode/sessions/` (3,156 session files).

### jcode sub-agents ARE recorded, and retroactively attributable

```
root sessions:            3,135
child sessions (parent_id):  21   (20 carry token usage)
```

Child sessions are ordinary session files with `parent_id` set to the parent's `id`. Their `token_usage` records are already parsed by Pulse today - they are simply not *labelled* as sub-agent work, so they silently inflate whatever project they land in.

```
MAIN     in= 118,547,022  out= 31,992,067  cacheRead= 14,079,334,643  cacheWrite= 234,487,093
SUBAGENT in=   5,218,003  out=  4,635,521  cacheRead=  3,159,581,894  cacheWrite=  42,398,938

MAIN total     14,464,360,825
SUBAGENT total  3,211,834,356   (18.2% of all jcode tokens)
```

**18.2% of jcode token volume is sub-agent work.** That is the number this feature makes visible. It is real, on disk, and needs no new logging.

### Two structural facts that WILL bite you

**1. Sub-agent trees nest.** 5 of the 21 children have a parent that is itself a child. A naive `parent_id != nil` check classifies correctly (any depth is still "sub-agent"), but if you ever attribute a child to "its parent's project", you must walk to the **root** ancestor, not one level up. Guard against cycles - the data is machine-written, but a cycle would hang the parse.

**2. A child's `working_dir` can differ from its parent's.** 20 of 21 match; 1 does not:

```
child:  /Users/joelsbastos/MYNE/Work/DataInnovation/dicdrepo
parent: /Users/joelsbastos/MYNE/Work/DataInnovation/delist-standalone
```

This is a real decision, not an edge case to skip: does a sub-agent's usage belong to the project **it ran in**, or the project **that spawned it**? The user wants per-project sub-agent columns, and attributing to the spawning project is what makes the "this project's work cost X" reading correct. Recommend root-ancestor attribution, and **confirm with the user** - it changes the numbers.

### Model and account coverage

The user asked for sub-agents "with Anthropic accounts or OpenAI accounts". Measured reality:

```
child session models: claude-opus-5 (majority), claude-opus-5[1m]
```

Every jcode sub-agent on this machine ran a Claude model. **No OpenAI sub-agents exist yet**, so the OpenAI path cannot be verified against real data today. Build it model-agnostically (attribution keys off `parent_id`, never off the model), and say plainly in your report that the OpenAI case is untested for want of data rather than claiming it works.

Separately established in the originating session: jcode has only ever produced **2** `gpt-5.6-sol` sessions, both with **zero** assistant turns and therefore zero usage. The user's real OpenAI usage lives in `~/.codex/sessions` (Codex CLI), tracked separately under the Codex tab.

---

## Where the code is

Repo: `~/MYNE/Projects/pulse` (Swift package, macOS menu-bar app, MIT, remote `Byte-de/pulse`).

| File | Relevance |
|---|---|
| `Sources/Pulse/Providers/Jcode/JcodeLogParser.swift` | parses `~/.jcode/sessions/session_*.json`. **This is where `parent_id` must be read.** Currently decodes `id, title, model, working_dir, messages[]` and deliberately never decodes message `content`. |
| `Sources/Pulse/Core/Models/ProjectUsage.swift` | `ProjectUsage` / `SessionUsage` / `ProjectUsageAggregator`. The per-project rows the analytics table renders. |
| `Sources/Pulse/Core/Models/TokenUsage.swift` | `TokenTotals` (`input`, `output`, `cacheRead`, `cacheWrite`, `costUSD`), `TokenUsageReport`, `ModelShare`. |
| `Sources/Pulse/UI/Breakdown/BreakdownView.swift` | the analytics table and its column headers. |
| `Sources/Pulse/UI/Breakdown/BreakdownViewModel.swift` | selection, sorting, loading. |
| `Sources/Pulse/UI/Panel/TokenUsageCard.swift` | the panel's fast-review card. |
| `Sources/Pulse/Core/Pricing/ModelPricing.swift` | `PricingTable.cost(model:input:output:cacheRead:cacheWrite5m:cacheWrite1h:)`. Already covers Anthropic and OpenAI models. |

### Constraint: `JcodeLogParser` currently reuses Claude's types

`JcodeLogParser` aliases `ClaudeLogParser.Entry` and `ClaudeLogParser.SessionFile`, and its cached aggregate is `Codable` and persisted on disk by `FileAggregationCache`. Consequences:

- Adding a sub-agent flag to the cached shape **changes the on-disk cache format**. Bump the cache name (currently `jcode-files-v2`) so stale caches are not decoded into the new shape. Getting this wrong means every user silently reads a cache with no sub-agent data and sees zeros.
- Adding a field to `ClaudeLogParser.Entry` affects the Claude parser too. Prefer carrying the flag on the **session** aggregate rather than per entry, since sub-agent-ness is a property of the session, not the message.

### Constraint: `swift test` does not run on this machine

No Xcode installed, so the `Testing` module is unavailable and **every** existing test file fails to compile locally. Do not read that as your change breaking the suite. Commit real tests in `Tests/PulseTests/`, and additionally verify with a standalone `swiftc` harness under `$TMPDIR` that imports the real sources - that is how every number in this document was produced. CI (macOS 26 runner) runs the real suite.

Build and install locally with:

```
swift build
./scripts/build-app.sh --install
```

The app is a menu-bar agent (`LSUIElement`), bundle id `de.byte.pulse`, settings in `defaults read de.byte.pulse`.

---

## Definition of done

1. `JcodeLogParser` reads `parent_id` and marks each session as main or sub-agent, resolving to the **root ancestor** for project attribution (cycle-safe).
2. Cache name bumped, so no user reads a stale aggregate into the new shape.
3. Panel token card shows sub-agent usage alongside main, compactly.
4. Analytics table gains the sub-agent columns agreed with the user (see the open question above - agree the column set BEFORE building).
5. Costs computed via the existing `PricingTable`, so a model missing a price contributes nil rather than a silent zero.
6. Committed tests covering: `parent_id` detection, nested depth >= 2, a child whose `working_dir` differs from its parent's, cost split across buckets, and the totals reconciling (main + sub = all).
7. Meta-test: plant defects (treat children as main; attribute one level up instead of to the root; drop the cache bump) and show each is caught. A test that has never failed on a real defect proves nothing.
8. Verified in the running app against real data, with the 18.2% figure reproducible.

## Do not

- Do not touch Claude Code sub-agent tracking. Out of scope by explicit instruction, and impossible anyway (Appendix A).
- Do not decode jcode message `content`. The parser is deliberately content-blind; only `token_usage` and metadata are read.
- Do not build the 13-column table before the user has agreed the column set.
- Do not claim the OpenAI sub-agent path is verified. No such data exists on this machine yet.

## Open questions for the user (ask before building)

1. **Column set.** Thirteen-plus columns will not fit. Which go in the main table, which move to the drill-down?
2. **Attribution.** Sub-agent usage counts toward the project that **spawned** it (recommended) or the project it **ran in**? One real case differs.
3. **Cache tokens.** The user listed input and output. `cacheRead` is by far the largest component (14.1B of 14.5B main tokens). Fold cache into input, show it as its own column, or omit it? Omitting understates by an order of magnitude.

---

## Appendix A: why Claude Code sub-agents are impossible (do not re-investigate)

Measured across `~/.claude/projects`, `~/.claude-elara/projects`, `~/.claude-joeld/projects`:

```
Task tool invocations:        418
isSidechain:true records:       0
isSidechain:false records: 131,567
```

Claude Code records that a sub-agent was launched, and never writes the sub-agent's own turns. The 21 `Task` `tool_result` blocks were inspected directly: they contain only text output (one is a truncation notice pointing at a file), with **no token counts anywhere**. The tokens do not exist locally in any form, so no local tool can recover them - past or future.

Consequence worth telling the user again if it comes up: Pulse's live 5-hour and weekly **gauges** come from the API and DO include Claude Code sub-agent consumption, while the **token history** cannot. That asymmetry is the mechanism behind a session gauge reading 100% while the token card looks modest.

The only honest future path for Claude Code would be correlating a `Task` invocation against the live utilization delta from `HistoryStore` (Pulse polls the endpoint every 60s). Approximate by construction, bounded by the 60s sampling floor. Not part of this task.

## Appendix B: commands that produced these numbers

```bash
# child vs root sessions, and the 18.2% split
python3 -c "
import json,glob,os
fs=[p for p in glob.glob(os.path.expanduser('~/.jcode/sessions/*.json')) if os.path.basename(p).startswith('session_')]
def tok(d):
    i=o=cr=cw=0
    for m in d.get('messages') or []:
        tu=m.get('token_usage')
        if tu:
            i+=tu.get('input_tokens') or 0; o+=tu.get('output_tokens') or 0
            cr+=tu.get('cache_read_input_tokens') or 0; cw+=tu.get('cache_creation_input_tokens') or 0
    return i,o,cr,cw
m=[0]*4; s=[0]*4
for p in fs:
    try: d=json.load(open(p))
    except: continue
    t=tok(d); tgt = s if d.get('parent_id') else m
    for k in range(4): tgt[k]+=t[k]
print('main', m, sum(m)); print('sub', s, sum(s))
print('sub share {:.1f}%'.format(sum(s)/(sum(m)+sum(s))*100))
"
```

Nesting depth and `working_dir` divergence were measured with the same pattern, resolving `parent_id` through an `id -> session` map built from the same file list.
