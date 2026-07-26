# Handoff: crdt_lf non-BMP (surrogate-pair) corruption — bug + PR test suite

Prepared for a fresh Claude Code session working directly in a clone/fork of the
crdt_lf source repo. Goal: (1) a test that demonstrates the broken behavior,
(2) a fix, (3) a test proving the fix. Everything below was verified against
crdt_lf **3.2.1 and 3.3.0** — the bug is present and identical in both.

---

## TL;DR

`CRDTFugueTextHandler` stores one element per **UTF-16 code unit**, so a non-BMP
character (emoji, astral CJK, math alphanumerics) is split into two elements,
each holding a **lone surrogate**. Element text is serialized with
`utf8.encode(...)`. `utf8.encode` of a lone surrogate is invalid UTF-8, and Dart
substitutes **U+FFFD** (bytes `EF BF BD`). Result: every non-BMP character is
corrupted to `��` the moment ops are serialized — i.e. on cross-replica sync
**and on snapshot/persistence**. The originating in-memory replica reads
correctly, which hides the bug from local/happy-path tests.

Reproduced: `😀` → `��`, `𠀀X𝐀` → `��Y��`, `a😀b` → `a��b`. Deterministic;
survives both merge orderings and duplicated delivery (it is not a merge bug —
it is a serialization bug). Convergence is to garbage: all remote replicas
agree on the corrupted value, and the value is still *valid UTF-16* (U+FFFD is a
legal BMP char), so a "no lone surrogate" check does NOT catch it — only
assertions on specific expected content do.

---

## Upstream repo

- Repository: https://github.com/MattiaPispisa/crdt (monorepo)
- Package path in repo: `packages/crdt_lf/`
- All file paths below are **relative to `packages/crdt_lf/`** unless marked ABSOLUTE.

---

## Root cause — exact evidence (line numbers are crdt_lf 3.3.0)

1. Per-code-unit element splitting (insert and update):
   - `lib/src/handler/fugue_text/handler.dart:53`  `for (var i = 0; i < text.length; i++)`  ← `text.length` = UTF-16 code units
   - `lib/src/handler/fugue_text/handler.dart:57`  `text: text[i]`                         ← `text[i]` = ONE UTF-16 code unit (a lone surrogate for non-BMP)
   - `lib/src/handler/fugue_text/handler.dart:81,98`  same pattern in `update()`

2. Lossy serialization of the lone-surrogate element value:
   - `lib/src/handler/fugue_text/operation.dart:131`  `final textBytes = utf8.encode(item.text);`  ← insert op body  (**corruption site**)
   - `lib/src/handler/fugue_text/operation.dart:306`  `final textBytes = utf8.encode(item.text);`  ← update op body  (**corruption site**)
   - decode counterparts use `utf8.decode(...)` in the same files (`fromBodyBytes`)

3. Snapshot/persistence path (SAME defect — confirmed):
   - `lib/src/handler/fugue_text/handler.dart:210`  `encodeValue` → `utf8.encode(value)`  ← per-element snapshot value
   - `lib/src/handler/fugue_text/handler.dart:215`  `decodeValue` → `utf8.decode(bytes)`

Dart specifics that make this fail: `String.length`/`String[i]` are UTF-16 code
units; `utf8.encode('\uD83D')` (lone high surrogate) → `[0xEF,0xBF,0xBD]`.

---

## Full fix surface (all `utf8.encode`/`utf8.decode` of possibly-split text)

Primary (the reproduced bug — Fugue handler; ALWAYS splits, so always corrupts):
- `lib/src/handler/fugue_text/operation.dart:131` (insert encode) + matching decode
- `lib/src/handler/fugue_text/operation.dart:306` (update encode) + matching decode
- `lib/src/handler/fugue_text/handler.dart:210` (snapshot encodeValue) / `:215` (decodeValue)

Secondary (the OTHER text handler — `CRDTTextHandler`; stores runs of code units,
so it CONDITIONALLY corrupts only when an op/segment boundary splits a pair —
VERIFY empirically, do not assume):
- `lib/src/handler/text/handler.dart:142` (encodeValue) / `:345` (decode)
- `lib/src/handler/text/operation.dart:88,221` (encode) / `:56,202` (decode)
- Note this handler operates on `.codeUnits` (`handler.dart:152,193,195,222`).

Not implicated: `JsonValueCodec` (`lib/src/handler/value_codec.dart`) — used by
register/map/or-set for their VALUES, which go through `jsonEncode`; jsonEncode of
a full string is fine. Only the text handlers hand `utf8.encode` a lone surrogate.

---

## Fix options (design decision for the PR)

Option A — **surrogate-safe wire encoding, keep per-code-unit granularity (minimal, recommended).**
Replace `utf8.encode`/`utf8.decode` of an individual element value with a codec
that round-trips a lone UTF-16 code unit losslessly. Cheapest: store the code
unit as a 16-bit integer (big-endian `uint16`), or use WTF-8. This preserves
element identity, ordering, existing FugueElementID counters, and concurrent-edit
semantics — the only change is bytes on the wire. Lowest blast radius; easiest to
argue in review. Must bump the binary/schema version if the wire format is
versioned (check `lib/src/binary/binary.dart` and `Change` schemaVersion).

Option B — **one element per Unicode code point (rune), not per code unit.**
Iterate `text.runes` instead of `text[i]`, so a non-BMP char is a single element
whose value is a full (encodable) string. Cleaner conceptually and makes emoji a
single editable unit, BUT it changes element granularity — affects counters,
diffs, cursor math, and interop with any existing persisted docs. Bigger,
higher-risk PR. Probably a follow-up, not the first fix.

Recommendation: ship Option A first (correctness, backward-compatible-ish),
consider B separately.

---

## Test plan for the PR

The repo uses `package:test`. Add tests under `packages/crdt_lf/test/` (mirror
existing handler test layout). Cover:

1. **Cross-replica round-trip** (the core failing case): peerA inserts non-BMP
   text; `exportChanges()` → `importChanges()` into peerB; assert
   `tb.value == expected` (byte/code-unit equal), NOT just that replicas agree.
   Include `😀` (U+1F600), an astral CJK `𠀀` (U+20000), a math char `𝐀` (U+1D400).
2. **Snapshot/persistence round-trip**: insert non-BMP; `takeSnapshot()`;
   `Snapshot.fromBytes(snap.toBytes())`; import into a fresh doc; assert value.
3. **Diff-driven ops** (matches the BrainFrame use case): walk a diff that splits
   a surrogate pair (e.g. `a😀b`→`a😃b` differs only in the low surrogate) into
   insert/delete ops; replicate; assert content.
4. **Adversarial delivery**: both merge orderings + one duplicated (re-sent, i.e.
   a separate idempotent `importChanges` call — NOT a duplicate within a single
   batch, which trips the topological sort's cycle check).
5. **Negative assertion that catches THIS bug**: assert exact expected content.
   Do NOT rely on an "is valid UTF-16 / no lone surrogate" check — the corruption
   produces valid U+FFFD and passes that check.

Structure each as "fails before fix, passes after." The existing standalone repro
below already encodes all of this and can be ported into `package:test` cases.

---

## Existing artifacts in the current playground (ABSOLUTE paths)

These are in the exploration repo, NOT crdt_lf — copy/port them into the fork.

- Full adversarial repro (standalone `main()`, prints per-case PASS/FAIL, dumps the
  malformed op bytes showing `ef bf bd`):
  `/home/marvin/src/brainframe/crdt_playground/bin/i18n_surrogate_test.dart`
- Playground project (has `crdt_lf`, `diff_match_patch ^0.4.1`, `hlc_dart` deps):
  `/home/marvin/src/brainframe/crdt_playground/`
  - `pubspec.yaml`, `bin/crdt_playground.dart` (many CRDT exploration scenarios)

Read-only reference copies of the library source (for reading current behavior):
- `/home/marvin/.pub-cache/hosted/pub.dev/crdt_lf-3.3.0/lib/src/handler/fugue_text/handler.dart`
- `/home/marvin/.pub-cache/hosted/pub.dev/crdt_lf-3.3.0/lib/src/handler/fugue_text/operation.dart`
- `/home/marvin/.pub-cache/hosted/pub.dev/crdt_lf-3.3.0/lib/src/handler/text/handler.dart`
- `/home/marvin/.pub-cache/hosted/pub.dev/crdt_lf-3.3.0/lib/src/handler/text/operation.dart`

---

## Minimal repro (paste-able sanity check, ~12 lines)

```dart
import 'package:crdt_lf/crdt_lf.dart';
void main() {
  final a = CRDTDocument(peerId: PeerId.parse('aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa'));
  final ta = CRDTFugueTextHandler(a, 't');
  ta.insert(0, '😀');
  print(ta.value == '😀'); // true  (local, in-memory — hides the bug)

  final b = CRDTDocument(
    peerId: PeerId.parse('bbbbbbbb-bbbb-4bbb-bbbb-bbbbbbbbbbbb'),
    documentId: a.documentId);
  CRDTFugueTextHandler(b, 't');
  b.importChanges(a.exportChanges());
  final tb = CRDTFugueTextHandler(b, 't');
  print(tb.value == '😀'); // false -> "??"  (remote, after serialization)
  print(tb.value.codeUnits); // [0xfffd, 0xfffd]
}
```

---

## Gotchas for the new session (do not re-learn these)

- **Local reads hide it.** The originating replica keeps original half-strings in
  its in-memory tree and reconcatenates, so it reads correctly. Only a replica
  built FROM serialized bytes shows garbage. Always assert on a second replica.
- **"Valid UTF-16" is the wrong guard.** U+FFFD is a legal BMP char; the corrupted
  string passes a surrogate-wellformedness check. Assert on expected content.
- **Duplicated delivery = a separate import call**, not a duplicate entry inside a
  single `importChanges` list (that triggers `CrdtException: Cycle detected`).
- **PeerId format**: must match UUID-v4 regex — version nibble `4` after 2nd dash,
  variant nibble ∈ {8,9,a,b}. Recognizable valid ids used above:
  `aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa`, `bbbbbbbb-bbbb-4bbb-bbbb-bbbbbbbbbbbb`.
- **Two text handlers exist**: `CRDTFugueTextHandler` (definitely broken, always
  splits) and `CRDTTextHandler` (code-unit runs; verify whether/when it splits).
- If the wire format is versioned, a fix that changes element byte layout needs a
  schema/version bump + back-compat consideration for already-persisted docs.
```
