# Findings: Unicode status of `crdt_lf`'s `change()` method

Verified against **crdt_lf 3.4.2** (the version pinned in this playground's
`pubspec.lock`). Test suite lives in [`test/`](test/); run it with `dart test`.

Result: **107 pass, 29 fail.**

---

## TL;DR

1. **The historical non-BMP corruption bug is fixed.** All six `utf8.encode` /
   `utf8.decode` call sites named in `crdt_lf_surrogate_bug_handoff.md` now use
   WTF-8 in 3.4.2. Tier 0 (12 tests) passes, and the old standalone repro
   (`bin/i18n_surrogate_test.dart`) reports 36 checks / 0 failures. Emoji no
   longer turn into `U+FFFD` on sync or snapshot.
2. **`change()` itself is sound for Unicode on a single replica.** 250
   randomised round-trips per handler over a deliberately hostile alphabet
   (astral pairs sharing a high or low surrogate, unpaired surrogates,
   combining marks, ZWJ sequences, regional indicators, literal `U+FFFD`, NUL,
   CRLF) pass through all three paths: in-memory, exported-changes replica, and
   snapshot restore.
3. **The remaining Unicode exposure is concurrency, and WTF-8 cannot fix it.**
   Two replicas editing the same non-BMP character concurrently converge on
   **ill-formed UTF-16**, including code points that neither replica ever typed.
   Both handlers are affected. See Finding A.
4. **Two of the failures are not Unicode bugs at all.** They were found by the
   Unicode tests only because astral characters multiply the number of diff
   segments `change()` emits. Both reduce to plain ASCII, and one is a hard
   crash. See Findings B and C. **Fix these first** — some of the tier 1–4
   Unicode failures may be downstream of Finding B.

---

## Where `change()` sits

Both text handlers' `change()` are identical:
`lib/src/handler/fugue_text/handler.dart:130` and
`lib/src/handler/text/handler.dart:97`. Each calls `myersDiff(value, newText)`
and walks the segments emitting `insert`/`delete` with a running `offset`.

`myersDiff` (`lib/src/algorithm/meyers_diff/meyers_diff.dart`) is **UTF-16
code-unit based end to end**:

- `:131`, `:145` — `_commonPrefix` / `_commonSuffix` compare `codeUnitAt`
- `:103-104` — the shortest-edit-script runs on `.codeUnits`
- `:307`, `:318` — `_coalesce` builds segment text one code unit at a time via
  `String.fromCharCodes`

Consequence, hand-traced and confirmed: `a😀b` → `a😃b` is
`[61, D83D, DE00, 62]` → `[61, D83D, DE03, 62]`. The common prefix matches the
*shared high surrogate*, so prefix = 2, and `change()` emits
`delete(2, 1)` + `insert(2, "\uDE03")`. The resulting emoji is assembled from a
high surrogate belonging to one operation and a low surrogate belonging to
another. In `CRDTFugueTextHandler` those are two independent tree elements with
nothing keeping them adjacent.

That is fine sequentially — tier 1 and tier 3 prove it round-trips exactly. It
is not fine concurrently.

---

## Finding A — concurrent edits tear surrogate pairs (genuine Unicode defect)

**Affects both handlers.** 8 hard-invariant failures in
[`test/tier2_concurrent_grapheme_test.dart`](test/tier2_concurrent_grapheme_test.dart)
(4 per handler), plus 7 advisory grapheme failures.

With genuine concurrent edits there is no single correct output text, so tier 2
asserts invariants instead of content:

1. both replicas converge and delivery is idempotent
2. the result is well-formed UTF-16 (no lone surrogates)
3. no **novel** code point appears — nothing that is absent from the base text
   and from both replicas' local results

Invariant 1 holds everywhere. Invariants 2 and 3 fail. Failing cases:

| case | base | replica A | replica B |
|---|---|---|---|
| `both-replace-low-surrogate-of-same-emoji` | `a😀b` | `a😃b` | `a𠀀b` |
| `shared-low-surrogate-collision` | `x𠀀y` | `x𝐀y` | `x😀y` |
| `delete-emoji-while-other-modifies-it` | `a😀b` | `ab` | `a😃b` |
| `zwj-family-concurrent-edit` | `👨‍👩‍👧` | `👨‍👩‍👦` | `👨` |

Worked example (the ZWJ case). `👧` is `D83D DC67` and `👦` is `D83D DC66`, so
A's `change()` deletes only `DC67` and inserts only `DC66`. B's `change()`
deletes the whole tail including the `D83D`. The union of those operations
leaves A's new low surrogate with no high surrogate in front of it. Both
replicas converge on `[D83D, DC68, DC66]` — `👨` followed by a lone `U+DC66`.

This is a convergence-to-invalid-text defect, not a serialization defect: the
bytes on the wire are faithful, and WTF-8 is working exactly as intended. The
element **granularity** is the problem. It is the case Option B in the original
handoff doc (one element per rune rather than per code unit) would address, and
Option A cannot.

Also reachable without any concurrency, because both handlers index by code
unit with no pair guard — 4 further failures under
`code-unit API surface`:

```dart
final t = CRDTFugueTextHandler(CRDTDocument(), 't');
t.insert(0, '😀');
t.insert(1, 'X');       // index 1 is INSIDE the surrogate pair
// value == "\uD83D X \uDE00"  -> ill-formed UTF-16, faithfully replicated

t.delete(2, 1);         // on "a😀b": removes the low surrogate only
// value == "a\uD83Db"
```

A cursor position computed from a code-unit offset can land there by accident.
If BrainFrame drives these handlers from anything other than whole-string
`change()` calls, it needs to clamp indices to code-point boundaries itself.

---

## Finding B — `CRDTFugueTextHandler` misorders an insert placed before a prior insert

**Not a Unicode bug. Severity: high** — silent, local, and hit by ordinary
typing at the start of a line.

Minimal repro (no Unicode, no concurrency, no serialization, no transaction):

```dart
final t = CRDTFugueTextHandler(CRDTDocument(), 't');
t.insert(0, 'abc');
t.insert(0, 'Z');     // "Zabc"  — correct
t.insert(0, 'QQ');    // "ZQQabc" — WRONG, want "QQZabc"
```

A chain of prepends scrambles outright: five successive `insert(0, …)` of
`a,b,c,d,e` yields `bcdea` instead of `edcba`.

Not specific to index 0 — the pattern is "insert immediately before text that an
earlier local insert added":

```dart
t.insert(0, 'abc');
t.insert(1, 'Z');     // "aZbc" — correct
t.insert(1, 'QQ');    // "aZQQbc" — WRONG, want "aQQZbc"
```

Reachable through `change()` alone, which is how the Unicode suite found it:

```dart
t.insert(0, 'abc');
t.change('Xbc');
t.change('QXbc');     // "XQbc" — WRONG
```

Notes:

- The **originating replica's own in-memory value is already wrong**. Replication
  and snapshotting are faithful; they just propagate the wrong order. So this is
  a state/anchoring bug, not a codec bug.
- Insertions in the middle of untouched text and appends at the end are fine.
- `CRDTFugueListHandler` has the identical defect (`c,b,a` prepends give
  `b,c,a`), which locates it in the **shared Fugue sequence layer**, not in the
  text handler or its codec. Likely locus is the `originBefore(index)` /
  `nodeAfter(...)` anchoring used by `insert` (`fugue_text/handler.dart:47-48`)
  when the node at `index` was added by an earlier operation — but the exact
  line is not pinned; this was characterised behaviourally.
- **`CRDTTextHandler` is not affected.**

Pinned by
[`test/tier5_isolated_bugs_test.dart`](test/tier5_isolated_bugs_test.dart)
(group "BUG 1"), 6 failing tests plus 1 passing control.

---

## Finding C — `CRDTTextHandler.compound` throws on a leftward insert in a transaction

**Not a Unicode bug. Severity: high** — it is an uncaught exception that aborts
the whole transaction, and `change()`'s own docstring recommends transactions.

```dart
final d = CRDTDocument();
final t = CRDTTextHandler(d, 't');
t.insert(0, 'abc');
d.runInTransaction(() {
  t..change('abcZ')..change('Qabc Z');
});
// RangeError (end): Invalid value: Not in inclusive range 0..1: -3
```

Also reachable with bare inserts, and with pure ASCII:

```dart
d.runInTransaction(() {
  t..insert(2, 'M')   // insert further right
   ..insert(0, 'Q');  // then further LEFT, same transaction
});
```

Root cause, in the library source:

- `lib/src/handler/text/handler.dart:326` —
  `_isContiguousInsertion` is
  `accumulator.index + accumulator.text.length >= current.index`.
  It has **no lower bound**, so it is also satisfied when `current.index` is
  *smaller* than `accumulator.index`.
- `lib/src/handler/text/handler.dart:267` — `compound` then evaluates
  `accumulator.text.substring(0, current.index - accumulator.index)` with a
  negative end and throws.

Stack path is `CRDTDocument.runInTransaction` → `TransactionManager.commit` →
`Compound.compact` (`lib/src/compound/compound.dart:33`) →
`CRDTTextHandler.compound`.

The identical sequence **outside** a transaction produces the correct result, so
the diff and the emitted operations are right; only the commit-time compaction
is broken. A guard of the form
`current.index >= accumulator.index && current.index <= accumulator.index + accumulator.text.length`
looks like the minimal fix, but the second compaction branch at `:279-284`
(`_isDeletingPartialInsertion`) uses the same subtraction and should be checked
for the same hole.

`CRDTFugueTextHandler` does not throw on this sequence.

Pinned by
[`test/tier5_isolated_bugs_test.dart`](test/tier5_isolated_bugs_test.dart)
(group "BUG 2"), 2 failing tests plus 2 passing controls.

---

## What passed (equally important)

- **Tier 0** (12/12): the historical `U+FFFD` corruption is gone on both
  handlers, across sync and snapshot, including the `change()`-splits-a-pair
  case that originally reported it.
- **Tier 1** (51/52): all 24 corpus `(from, to)` pairs round-trip exactly on
  both handlers through all three paths — surrogate splits, shared high and low
  surrogates, ZWJ families, regional indicators, NFC↔NFD, combining-mark
  rebasing, unpaired surrogates in the *input*, literal `U+FFFD`, NUL, CRLF,
  bidi controls, variation selectors, skin-tone modifiers. The single failure is
  Finding B.
- **Tier 3** (5/6): 250 randomised single-`change()` trials per handler, plus a
  dedicated "no `U+FFFD` introduced" property, all pass. The single failure is
  the chained-`change()` test, i.e. Finding B again.
- **Tier 4** (13/14): `change()` inside `runInTransaction` matches the
  non-transactional path on all 5 multi-segment edits for both handlers, and
  survives replication and snapshot. Transactions do **not** cause stale index
  resolution. The single failure is Finding C.
- Convergence and `importChanges` idempotence hold in every tier 2 case,
  including duplicated delivery.

---

## Suite layout

| file | what it does |
|---|---|
| `test/support/unicode_support.dart` | handler-agnostic facade, replication and snapshot helpers, well-formedness / novel-code-point / orphan-ZWJ inspectors |
| `test/support/unicode_corpus.dart` | 24 `(from, to)` pairs, each probing a distinct diff property |
| `test/tier0_serialization_regression_test.dart` | guards the WTF-8 fix; fails loudly if a `utf8` call site returns |
| `test/tier1_change_roundtrip_test.dart` | corpus × both handlers × {local, replicated, snapshot} |
| `test/tier2_concurrent_grapheme_test.dart` | concurrent `change()` across surrogate and grapheme boundaries; hard vs. advisory invariants; code-unit API surface |
| `test/tier3_property_fuzz_test.dart` | seeded fuzz with a differential oracle; failures print a paste-ready Dart literal |
| `test/tier4_transaction_test.dart` | `change()` inside vs. outside `runInTransaction` |
| `test/tier5_isolated_bugs_test.dart` | minimal ASCII reductions of Findings B and C, with controls |

Two conventions worth keeping if this is ported upstream:

- **Never assert on the originating replica alone.** It keeps the original
  half-strings in memory and reconcatenates them, so a local read hides any
  wire-format defect. Every assertion goes through a replica rebuilt from
  exported changes or from snapshot bytes.
- **`U+FFFD` is valid UTF-16.** A "no lone surrogate" check does not catch
  replacement-character corruption, which is why tiers 1 and 3 assert exact
  expected content and carry a separate `U+FFFD`-count property. Well-formedness
  checks are used only in tier 2, where concurrency means there is no single
  correct answer.

Dev dependency added: `characters` (grapheme-cluster dumps in failure messages).

---

## Next steps

- Findings B and C are clean, minimal, Unicode-free bug reports against
  `MattiaPispisa/crdt`, package `packages/crdt_lf/`. B is the more serious of the
  two (silent data misordering vs. a loud crash).
- **3.4.2+1 is available** and was not tested; re-run the suite against it before
  filing anything upstream.
- Re-run tier 2 after Finding B is fixed. Some of those failures may be
  downstream of it, since the local `change()` results feeding the merges are
  themselves computed by the buggy path.
- If BrainFrame needs emoji-safe concurrent editing, Finding A is an argument
  for per-rune elements (handoff Option B) rather than per-code-unit. As a
  narrower mitigation, `change()` could snap diff segment boundaries to
  code-point boundaries — that would remove the "half-pair as its own element"
  case entirely for the single-replica path and shrink the concurrent exposure.
