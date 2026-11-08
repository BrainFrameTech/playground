# crdt_lf 3.5.0 — snapshot byte determinism

**Question:** do two peers that hold the same set of edits produce byte-identical
`takeSnapshot(pruneHistory: false).toBytes()`?

**Answer: no.** The snapshot is byte-identical only by accident. Two independent
causes reorder bytes, and both are fixed by a canonical re-encoding. A third
cause, a pruning bug, changes a version-vector *value*, and canonicalisation
can't fix that.

Test: `test/snapshot_determinism_test.dart` (run with
`dart test test/snapshot_determinism_test.dart`; a per-comparison summary
prints at the end). Paths below are relative to
`~/.pub-cache/hosted/pub.dev/crdt_lf-3.5.0/lib/src/`.

## Snapshot layout (snapshot.dart:135-157)

`id` (SHA-256 of the **sorted** VV, snapshot.dart:166-180, order-independent) →
version vector bytes → handler entries in `data` map order → each Fugue
handler payload = live nodes in tree order + `ElementIdFloor` trailer
(fugue_sequence_handler.dart:206-222).

## The three suspicions, checked against source

| Suspicion | Verdict |
|---|---|
| VV `toBytes` iterates in stored order | **Confirmed.** version_vector.dart:260 iterates `_vector.entries`; the map is filled by `DAG.addNode` → `_versionVector.update` (dag/graph.dart:150), so a peer's position is where its *first change arrived*. `importChanges` topologically sorts each batch (document.dart:1182), but separate batches arrive in network order. |
| `ElementIdFloor.write` iterates map order | **Confirmed, but the cause isn't arrival order.** element_id_floor.dart:26. The map comes from `_maxCountersByPeer` (fugue/fugue_cache.dart:78-94): peers appear in the order they occur in `knownElementIds()`, which is snapshot nodes **in tree order**, then post-snapshot ops **in HLC-sorted replay order** (fugue_sequence_handler.dart:97-104, handler.dart:105-111). Then `mergeInto` appends floor-only peers at the end (fugue_cache.dart:92). For a peer that has never snapshotted, this order is deterministic. It changes once the peer has *any* `_lastSnapshot`, including a non-pruning one. |
| `Snapshot.toBytes` writes handlers in registration order | **Confirmed in source** (snapshot.dart:147; map built at document.dart:857 from `_handlers`, which is registration order). It doesn't show up in these tests because each document has a single handler. It would show up if peers register several handlers in different orders, e.g. lazily. The container manifest (document.dart:863-870) has the same property. |

## Results per case

| # | Case | Raw bytes | Differing component | Canonical |
|---|---|---|---|---|
| 1 | 2 writers, observers get A→B vs B→A | **differ** | VV order only | match |
| 2 | 3 writers × 6 orders; 4 writers × 24 orders | **differ** (every order except the one that matches the reference) | VV order only | match |
| 3 | delete on another peer | match | none (causality forces A's change to arrive first everywhere) | match |
| 4 | concurrent inserts at same position (seeded by a third peer) | **differ** | VV order only; node payload identical | match |
| 5 | A compacts (`pruneHistory: true`) midway | **differ** | VV order (`[A,C,B]` vs `[A,B,C]`) **and** floor order (`[A,C,B]` vs `[A,B,C]`) | match |
| 5b | A takes a *non-pruning* snapshot midway | **differ** | floor order only | match |
| 6 | restart via `importSnapshot` | **differ** | floor order: original `[B,A,C]` (HLC order) → `[A,C,B]` (tree order) | match |
| 7 | *(extra)* `importSnapshot` of an older snapshot while holding newer changes | **differ** | **VV value**: `A@…798.0` instead of `A@…798.2`; snapshot `id` differs too | **still differs** |

Details:

- **Case 3, tombstones:** deleted elements are **not** in the handler payload.
  `FugueTree.nodes()` emits live nodes only (algorithm/fugue/tree.dart:90-99).
  Their counters do survive in the floor: A's floor entry is 19 although only
  counters 0-9 are still live. The test asserts this.
- **Case 5:** after the prune, A's DAG version vector has lost every pruned
  peer (dag/graph.dart:133). New changes add peers back in arrival order, and
  `getVersionVector` (document.dart:672-677) appends the snapshot-only peers
  after them. The floor carried over from the compaction is appended last
  (fugue_cache.dart:92). Counter *values* match the peer that never compacted:
  the carry-over works, and only the order differs.
- **Case 5b / 6:** `takeSnapshot(pruneHistory: false)` still stores the result
  as `_lastSnapshot` (document.dart:880). From then on, `knownElementIds` walks
  the snapshot's nodes in tree order instead of replaying history in HLC order.
  **Calling `takeSnapshot(pruneHistory: false)` twice in a row, with no edits in
  between, gives different bytes** (case 6, "A second takeSnapshot"). A restart
  from the snapshot, whether under the same or a new peer ID, gives the
  second-snapshot bytes, not the original's.
- **Case 7, a real bug, not just ordering:** `DAG._removeNodes`
  (dag/graph.dart:121-134) calls `_versionVector.remove(peerIds)` for every peer
  that had *any* node pruned, even when newer nodes of that peer survive
  (`prune` only removes nodes `<=` the given VV, graph.dart:78-93).
  `getVersionVector` then merges in the snapshot's *older* clock for that peer.
  The handler content is correct, but the VV under-reports what the peer holds.
  So the snapshot ID differs, and the peer will look behind to anyone comparing
  version vectors. This happens with `importSnapshot` / `mergeSnapshot` /
  `garbageCollect` whenever the pruning VV is older than the peer's own history.
  Normal `takeSnapshot(pruneHistory: true)` prunes at the full VV, so nothing of
  any peer survives the prune and this bug is never triggered there.

## Canonical form

Re-encode with the VV sorted by peer ID, handler entries sorted by key, and the
Fugue floor sorted by peer ID, keeping the node payload as is
(`canonical()` in the test). This makes **cases 1-6 match**. Things to know:

- It **does not fix case 7**: the VV *value* differs, not its order. The fix is
  in crdt_lf: `_removeNodes` should recompute the VV entry from the surviving
  nodes instead of deleting it. Alternatively, avoid importing a snapshot older
  than local history.
- Sorting the floor means parsing **inside** the handler blob. That needs the
  Fugue payload format (node list + `ElementIdFloor` trailer) and is
  handler-type-specific; other handler types would need their own
  canonicalizers.
- PeerId strings are lowercase fixed-format UUIDs, so sorting the strings
  equals sorting the 16 bytes. A `PeerId.parse` of upper-case input would break
  that equivalence.

## Other things in the snapshot that depend on one peer rather than on the edit set

- **The peer's own snapshot history** (cases 5, 5b, 6): whether and when it has
  snapshotted, compacted, or restarted changes the floor order, and the VV order
  after a prune.
- **Arrival order** (cases 1, 2, 4): the VV order.
- **Handler registration order** (source only, untested): handler entry order.
- **Not** peer-dependent: the snapshotting peer's ID, its local clock, and the
  local wall time are not written. `_advanceClockPast` uses `DateTime.now()`
  (document.dart:968) but only to advance the in-memory clock. The HLCs in the
  VV do carry the *authors'* wall-clock milliseconds, but those are part of the
  edits themselves, so they are the same on every peer. `documentId` is not in
  the snapshot. The snapshot `id` sorts the VV entries, so it doesn't depend on
  their order, but it does inherit case 7's wrong values.

## Implication for the sync design

Don't hash `toBytes()` directly. Hash the canonical form, or a purpose-built
digest such as the sorted VV plus the node payload. In addition, never let a
peer import a snapshot older than history it already holds, until the
`_removeNodes` VV bug is fixed upstream.
