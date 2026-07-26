import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crdt_lf/crdt_lf.dart';
import 'package:hlc_dart/hlc_dart.dart';

// Recognizable, mentally-distinct peer IDs for exploring crdt_lf.
// Each is a single repeated hex glyph. The version nibble ('4' after the
// second dash) and variant nibble (first of the fourth group, must be
// 8/9/a/b) are fixed by the UUID-v4 format PeerId.parse requires.
final peerA = PeerId.parse('aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa');
final peerB = PeerId.parse('bbbbbbbb-bbbb-4bbb-bbbb-bbbbbbbbbbbb');
final peerC = PeerId.parse('cccccccc-cccc-4ccc-8ccc-cccccccccccc');

void main(List<String> arguments) {
  statusFieldTwoWays();
}

/// Two peers each independently ADD a `status` register under a map-ref and set
/// different values. Run two ways:
///   A) per-peer UUID child id  -> STRUCTURAL loss (a whole field is orphaned)
///   B) deterministic shared id -> no structural loss; values resolve by LWW
void statusFieldTwoWays() {
  final regType = CRDTRegisterHandler<String>(CRDTDocument(), '_probe').handlerType;
  CRDTRegisterHandler<String> reg(CRDTDocument d, String id) =>
      CRDTRegisterHandler<String>(d, id);

  print('### A) per-peer UUID child id (the nightmare) ###\n');
  {
    final da = CRDTDocument(peerId: peerA)..registerDefaultFactories();
    da.registerFactory(regType, (d, id) => reg(d as CRDTDocument, id));
    final rootA = CRDTMapRefHandler(da, 'fm');
    final sA = reg(da, da.newHandlerId()); // random id -> unique per peer
    rootA.setRef('status', sA);
    sA.set('done');

    final db = CRDTDocument(peerId: peerB, documentId: da.documentId)
      ..registerDefaultFactories();
    db.registerFactory(regType, (d, id) => reg(d as CRDTDocument, id));
    final rootB = CRDTMapRefHandler(db, 'fm');
    final sB = reg(db, db.newHandlerId()); // DIFFERENT random id
    rootB.setRef('status', sB);
    sB.set('wip');

    merge(da, db);
    merge(db, da);
    print('  A.resolved = ${rootA.resolved}');
    print('  B.resolved = ${rootB.resolved}');
    print('  A wrote "done" (id ${sA.id.substring(0, 8)}), '
        'B wrote "wip" (id ${sB.id.substring(0, 8)})');
    final winner = rootA.getRef('status')?.id;
    print('  binding points at ${winner?.substring(0, 8)}; the other register '
        'still holds its value but is ORPHANED (a whole field lost).');
  }

  print('\n### B) deterministic shared child id (the fix) ###\n');
  {
    // Both peers derive the child id from the logical key -> SAME id.
    String childId(String key) => 'fm/$key';

    final da = CRDTDocument(peerId: peerA)..registerDefaultFactories();
    da.registerFactory(regType, (d, id) => reg(d as CRDTDocument, id));
    final rootA = CRDTMapRefHandler(da, 'fm');
    final sA = reg(da, childId('status'));
    rootA.setRef('status', sA);
    sA.set('done');

    final db = CRDTDocument(peerId: peerB, documentId: da.documentId)
      ..registerDefaultFactories();
    db.registerFactory(regType, (d, id) => reg(d as CRDTDocument, id));
    final rootB = CRDTMapRefHandler(db, 'fm');
    final sB = reg(db, childId('status')); // SAME id as A
    rootB.setRef('status', sB);
    sB.set('wip');

    merge(da, db);
    merge(db, da);
    print('  A.resolved = ${rootA.resolved}');
    print('  B.resolved = ${rootB.resolved}');
    print('  both point at child id "${sA.id}" -> ONE field, no orphan.');
    print('  the two VALUES contend via LWW: one of {done,wip} wins '
        '(expected for a scalar), converged=${rootA.resolved.toString() == rootB.resolved.toString()}');
  }

  // The distinction is INVISIBLE for a register (LWW drops a value regardless).
  // For a merge-type field (OR-set tags) it is stark: structural orphaning
  // discards data that a shared id would have MERGED.
  final setType = CRDTORSetHandler<String>(CRDTDocument(), '_p').handlerType;
  CRDTORSetHandler<String> set(CRDTDocument d, String id) =>
      CRDTORSetHandler<String>(d, id);

  print('\n### C) tags (OR-set), per-peer UUID -> a whole SET is orphaned ###\n');
  {
    final da = CRDTDocument(peerId: peerA)..registerDefaultFactories();
    da.registerFactory(setType, (d, id) => set(d as CRDTDocument, id));
    final rootA = CRDTMapRefHandler(da, 'fm');
    final tA = set(da, da.newHandlerId());
    rootA.setRef('tags', tA);
    tA.add('horror');

    final db = CRDTDocument(peerId: peerB, documentId: da.documentId)
      ..registerDefaultFactories();
    db.registerFactory(setType, (d, id) => set(d as CRDTDocument, id));
    final rootB = CRDTMapRefHandler(db, 'fm');
    final tB = set(db, db.newHandlerId());
    rootB.setRef('tags', tB);
    tB.add('fiction');

    merge(da, db);
    merge(db, da);
    print('  A wrote {horror}, B wrote {fiction}');
    print('  resolved = ${rootA.resolved}   <- one tag lost (a whole set orphaned)');
  }

  print('\n### D) tags (OR-set), deterministic id -> both tags MERGE ###\n');
  {
    final da = CRDTDocument(peerId: peerA)..registerDefaultFactories();
    da.registerFactory(setType, (d, id) => set(d as CRDTDocument, id));
    final rootA = CRDTMapRefHandler(da, 'fm');
    final tA = set(da, 'fm/tags');
    rootA.setRef('tags', tA);
    tA.add('horror');

    final db = CRDTDocument(peerId: peerB, documentId: da.documentId)
      ..registerDefaultFactories();
    db.registerFactory(setType, (d, id) => set(d as CRDTDocument, id));
    final rootB = CRDTMapRefHandler(db, 'fm');
    final tB = set(db, 'fm/tags');
    rootB.setRef('tags', tB);
    tB.add('fiction');

    merge(da, db);
    merge(db, da);
    print('  A wrote {horror}, B wrote {fiction}');
    print('  resolved = ${rootA.resolved}   <- both preserved, nothing lost');
  }
}

/// Answers three foundational handler-identity questions for the frontmatter
/// design: (Q1) can two handlers share a name/id? (Q2) how do they render?
/// (Q3) can a handler be renamed?
void handlerIdentityTest() {
  print('=== Q1: can two handlers share an id (name)? ===');
  // Same doc, same id, same type.
  final d1 = CRDTDocument(peerId: peerA);
  CRDTRegisterHandler<String>(d1, 'status');
  try {
    CRDTRegisterHandler<String>(d1, 'status');
    print('  same id, same type : NO ERROR (unexpected)');
  } on CrdtException catch (e) {
    print('  same id, same type : throws ${e.runtimeType}');
  }
  // Same doc, same id, DIFFERENT type.
  final d2 = CRDTDocument(peerId: peerA);
  CRDTRegisterHandler<String>(d2, 'x');
  try {
    CRDTMapHandler<String>(d2, 'x');
    print('  same id, diff type : NO ERROR (unexpected)');
  } on CrdtException catch (e) {
    print('  same id, diff type : throws ${e.runtimeType}  '
        '(collision is by id, type not even checked)');
  }
  print('  across peers, same id: allowed -- that IS how a field is shared (Q2)');

  print('\n=== Q2: how do handlers render? ===');
  final a = CRDTDocument(peerId: peerA);
  final sa = CRDTRegisterHandler<String>(a, 'status');
  final b = CRDTDocument(peerId: peerB, documentId: a.documentId);
  final sb = CRDTRegisterHandler<String>(b, 'status'); // SAME id on both peers
  sa.set('done');
  sb.set('wip');
  merge(a, b);
  merge(b, a);
  print('  shared id "status": A="${sa.value}" B="${sb.value}" '
      'converged=${sa.value == sb.value}');
  print('  registered handlers on A: ${a.registeredHandlers.keys.toList()}');
  print('  -> one id = one handler = one change stream; writes resolve by LWW.');

  print('\n=== Q3: can we rename a handler? ===');
  // There is no rename API. Using a NEW id makes a SEPARATE field: the new id
  // starts empty, and writers on the old vs new id never merge.
  final aState = CRDTRegisterHandler<String>(a, 'state'); // "rename" status->state
  print('  A creates "state": value=${aState.value}  '
      '("wip" did NOT move here -- new id has no history)');
  aState.set('A-via-state'); // A writes the NEW id
  sb.set('B-via-status'); //    B keeps writing the OLD id
  merge(a, b);
  merge(b, a);
  final bState = CRDTRegisterHandler<String>(b, 'state');
  print('  after A writes "state" and B writes "status", then merge:');
  print('    status: A="${sa.value}"  B="${sb.value}"');
  print('    state : A="${aState.value}"  B="${bState.value}"');
  print('  -> the field FORKED: A\'s and B\'s writes landed in different keys '
      'and never met.');
}

/// Validates the 3.4.0 stable-anchor API: stablePositionAt (index -> anchor id)
/// and indexOfStablePosition (anchor id -> current index), across concurrent
/// edits, a deletion of the anchored element, and an unknown element.
void stableAnchorTest() {
  print('=== Stable anchor round-trip ===\n');

  final docA = CRDTDocument(peerId: peerA);
  final ta = CRDTFugueTextHandler(docA, 't');
  ta.insert(0, 'Hello World'); // H0 e1 l2 l3 o4 _5 W6 o7 r8 l9 d10
  final docB = CRDTDocument(peerId: peerB, documentId: docA.documentId);
  final tb = CRDTFugueTextHandler(docB, 't');
  merge(docB, docA);
  print('base: A="${ta.value}"  B="${tb.value}"');

  // Anchor a caret right before "World" (index 6).
  final anchor = ta.stablePositionAt(6);
  print('\nanchor (caret before "World", idx 6) = $anchor');
  print('  now on A: ${ta.indexOfStablePosition(anchor)}   now on B: '
      '${tb.indexOfStablePosition(anchor)}   (expect 6 / 6)');

  // B inserts "Big " at the start -> the caret should shift right by 4.
  tb.insert(0, 'Big ');
  merge(docA, docB);
  merge(docB, docA);
  final idxA = ta.indexOfStablePosition(anchor)!;
  final idxB = tb.indexOfStablePosition(anchor)!;
  print('\nafter B inserts "Big " at 0: A="${ta.value}"');
  print('  caret A: $idxA -> substring "${ta.value.substring(idxA)}"');
  print('  caret B: $idxB -> substring "${tb.value.substring(idxB)}"');
  print('  (expect idx 10, substring "World")');
  // Capture the caret result NOW, before the deletion mutates the text.
  final caretOkA = idxA == 10 && ta.value.substring(idxA) == 'World';
  final caretOkB = idxB == 10 && tb.value.substring(idxB) == 'World';

  // Track a specific element ("W", now at index 10) and DELETE it.
  final wId = ta.nodeAt(10);
  print('\nelement at idx 10 = $wId  (char "${ta.value[10]}")');
  ta.delete(10, 1);
  merge(docA, docB);
  merge(docB, docA);
  print('after deleting "W": A="${ta.value}"');
  final delA = ta.indexOfStablePosition(wId);
  final delB = tb.indexOfStablePosition(wId);
  print('  indexOfStablePosition(W) A: $delA   B: $delB   '
      '(expect 10 / 10, where it was)');
  final delOkA = delA == 10; // and the deleted element's old spot now shows "orld"
  final delOkB = delB == 10;

  // Unknown element -> null.
  final bogus = FugueElementID(peerC, 999999);
  final bogusRes = ta.indexOfStablePosition(bogus);
  print('\nindexOfStablePosition(unknown) = $bogusRes  (expect null)');

  // Assertions (each checked at the stage where it is valid).
  var pass = true;
  void check(String label, bool ok) {
    print('  ${ok ? "PASS" : "FAIL"}  $label');
    if (!ok) pass = false;
  }

  print('\n--- assertions ---');
  check('caret tracks before "World" after prefix insert (A)', caretOkA);
  check('caret tracks before "World" after prefix insert (B)', caretOkB);
  check('deleted element resolves to its old position (A)', delOkA);
  check('deleted element resolves to its old position (B)', delOkB);
  check('unknown element resolves to null', bogusRes == null);
  print('\nRESULT: ${pass ? "ALL PASS" : "FAILURES PRESENT"}');
}

/// Fully-nested tags: a CRDTMapRefHandler whose 'tags' key points to a nested
/// OR-Set. Two variants:
///   CORRECT -- both peers bind 'tags' to the SAME child id, so the sets merge.
///   BROKEN  -- each peer creates its OWN child container (different ids); the
///              key->container binding is LWW, so one set is orphaned.
void nestedTagsUnderMap() {
  print('### CORRECT: both peers use the SAME child id for the tag set ###\n');
  {
    final docA = CRDTDocument(peerId: peerA)..registerDefaultFactories();
    final rootA = CRDTMapRefHandler(docA, 'frontmatter');
    final tagsA = CRDTORSetHandler<String>(docA, 'tags-set'); // shared, fixed id
    rootA.setRef('tags', tagsA);

    final docB = CRDTDocument(peerId: peerB, documentId: docA.documentId)
      ..registerDefaultFactories();
    final rootB = CRDTMapRefHandler(docB, 'frontmatter');
    final tagsB = CRDTORSetHandler<String>(docB, 'tags-set'); // SAME id
    rootB.setRef('tags', tagsB);

    tagsA.add('horror'); //  A
    tagsB.add('fiction'); // B
    merge(docA, docB);
    merge(docB, docA);

    print('  A resolved: ${rootA.resolved}');
    print('  B resolved: ${rootB.resolved}');
    print('  binding id: A->${rootA.getRef('tags')?.id}  '
        'B->${rootB.getRef('tags')?.id}');
  }

  print('\n### BROKEN: each peer creates its OWN child container ###\n');
  {
    final docA = CRDTDocument(peerId: peerA)..registerDefaultFactories();
    final rootA = CRDTMapRefHandler(docA, 'frontmatter');
    final tagsA = CRDTORSetHandler<String>(docA, docA.newHandlerId()); // random id
    docA.registerFactory(
      tagsA.handlerType,
      (d, id) => CRDTORSetHandler<String>(d, id),
    );
    rootA.setRef('tags', tagsA);

    final docB = CRDTDocument(peerId: peerB, documentId: docA.documentId)
      ..registerDefaultFactories();
    final rootB = CRDTMapRefHandler(docB, 'frontmatter');
    final tagsB = CRDTORSetHandler<String>(docB, docB.newHandlerId()); // DIFFERENT id
    docB.registerFactory(
      tagsB.handlerType,
      (d, id) => CRDTORSetHandler<String>(d, id),
    );
    rootB.setRef('tags', tagsB);

    tagsA.add('horror'); //  A, into its own container
    tagsB.add('fiction'); // B, into its own container
    merge(docA, docB);
    merge(docB, docA);

    print('  A resolved: ${rootA.resolved}   (A\'s own set holds: ${tagsA.value})');
    print('  B resolved: ${rootB.resolved}   (B\'s own set holds: ${tagsB.value})');
    print('  winning binding id: ${rootA.getRef('tags')?.id}');
    print('  => the losing set is ORPHANED: its tag is gone from the map view, '
        'though still in the log');
  }
}

/// A "tags" field is a mergeable list -> model it as an OR-Set. Two questions:
/// Q1: concurrent adds of different tags -- do both survive?
/// Q2: A adds two tags; B adds one then removes it -- what's the end result?
void mapListConflict() {
  print('### Q1: A adds horror, B adds fiction (concurrent) ###\n');
  {
    final docA = CRDTDocument(peerId: peerA);
    final tagsA = CRDTORSetHandler<String>(docA, 'tags');
    final docB = CRDTDocument(peerId: peerB, documentId: docA.documentId);
    final tagsB = CRDTORSetHandler<String>(docB, 'tags');

    tagsA.add('horror'); //  A
    tagsB.add('fiction'); // B
    print('  before merge:  A=${tagsA.value}  B=${tagsB.value}');
    merge(docA, docB);
    merge(docB, docA);
    print('  after merge:   A=${tagsA.value}  B=${tagsB.value}');
    print('  converged: ${sameSet(tagsA.value, tagsB.value)}');
  }

  print('\n### Q2: A adds {horror, fiction}; '
      'B adds fiction then removes it ###\n');
  {
    final docA = CRDTDocument(peerId: peerA);
    final tagsA = CRDTORSetHandler<String>(docA, 'tags');
    final docB = CRDTDocument(peerId: peerB, documentId: docA.documentId);
    final tagsB = CRDTORSetHandler<String>(docB, 'tags');

    tagsA.add('horror');
    tagsA.add('fiction');
    tagsB.add('fiction');
    tagsB.remove('fiction'); // removes only the fiction tag B itself observed
    print('  before merge:  A=${tagsA.value}  B=${tagsB.value}');
    merge(docA, docB);
    merge(docB, docA);
    print('  after merge:   A=${tagsA.value}  B=${tagsB.value}');
    print('  converged: ${sameSet(tagsA.value, tagsB.value)}');
  }
}

/// Is the HLC per peer or per document? It's per CRDTDocument *instance*:
/// the same peerId across two documents has two independent clocks, and all
/// handlers within one document share the one clock.
void hlcScope() {
  // Same peerId, two separate document instances.
  final doc1 = CRDTDocument(peerId: peerA);
  final doc2 = CRDTDocument(peerId: peerA);
  print('fresh:  doc1.hlc=${doc1.hlc}   doc2.hlc=${doc2.hlc}');

  // Write to doc1 ONLY.
  CRDTRegisterHandler<String>(doc1, 'k').set('hello');
  print('\nafter writing only to doc1 (same peerId on both):');
  print('  doc1.hlc = ${doc1.hlc}   (advanced)');
  print('  doc2.hlc = ${doc2.hlc}   (unchanged -- independent clock)');

  // Two handlers within doc1 share the one clock.
  final before = doc1.hlc;
  CRDTRegisterHandler<String>(doc1, 'other').set('x');
  print('\ntwo handlers in doc1 advance the SAME clock:');
  print('  before=$before  after=${doc1.hlc}');
}

/// Sanity check: does causality hold under a bad clock? A writes X, then Y
/// causally after X (Y.deps = [X]). Deliver to B out of order and duplicated.
void causalityUnderBadClock() {
  const fastMs = 4000000000000; // A's skewed-fast clock
  final docA = CRDTDocument(
    peerId: peerA,
    initialClock: HybridLogicalClock(l: fastMs, c: 0),
  );
  final statusA = CRDTRegisterHandler<String>(docA, 'status');

  statusA.set('X'); // change X
  statusA.set('Y'); // change Y, causally after X

  final all = docA.exportChanges();
  final cx = all.firstWhere((c) => c.deps.isEmpty);
  final cy = all.firstWhere((c) => c.deps.isNotEmpty);
  print('-- the causal chain (under A\'s fast clock) --');
  print('  X @ ${cx.hlc}  deps=[]');
  print('  Y @ ${cy.hlc}  deps=[${cy.deps.map((d) => d).join(", ")}]');
  print('  Y depends on X : '
      '${cy.deps.map((d) => d.toString()).contains(cx.id.toString())}');
  print('  Y.hlc > X.hlc  : ${cy.hlc.compareTo(cx.hlc) > 0}  '
      '(monotonic despite bad clock)');

  // Deliver to B out of order, with duplication, across several messages.
  final docB = CRDTDocument(peerId: peerB, documentId: docA.documentId);
  final statusB = CRDTRegisterHandler<String>(docB, 'status');

  print('\n-- adversarial delivery to B (applied / status / log size) --');
  void step(String label, List<Change> batch) {
    final n = docB.importChanges(batch);
    print('  $label -> applied $n, '
        'status=${statusB.value}, log=${docB.exportChanges().length}');
  }

  step('[Y]        (Y before X)', [cy]);
  step('[X]        (X arrives) ', [cx]);
  step('[Y]        (Y re-sent) ', [cy]);
  step('[X, Y]     (both dup)  ', [cx, cy]);

  print('\n  final: B.status=${statusB.value}  '
      'converged=${statusA.value == statusB.value}');
}

/// Can a normal user "correct" a poisoned HLC / the already-issued ops? No.
/// The value can be overwritten, but only by a peer whose clock is already at
/// the inflated time; an honest-clock peer cannot win, and the clock never
/// comes back down.
void correctionAttempt() {
  const fastMs = 4000000000000; // ~year 2096
  final docA = CRDTDocument(
    peerId: peerA,
    initialClock: HybridLogicalClock(l: fastMs, c: 0),
  );
  final statusA = CRDTRegisterHandler<String>(docA, 'status');
  final docB = CRDTDocument(peerId: peerB, documentId: docA.documentId);
  final statusB = CRDTRegisterHandler<String>(docB, 'status');

  statusA.set('from-A'); // fast-clock write
  merge(docB, docA); //     B accepts it -> B's clock is dragged to ~2096
  print('after merge: B.status=${statusB.value}  B.clock=${docB.hlc}');

  // A NORMAL USER on B edits to fix the value.
  statusB.set('user-fix');
  print('\nuser edits B -> "${statusB.value}"');
  print('  B write clock = ${docB.hlc}  (still ~2096 -- did NOT reset to now)');

  // A DIFFERENT, honest-clock peer C tries to correct with a real-time write.
  final docC = CRDTDocument(peerId: peerC, documentId: docA.documentId);
  final statusC = CRDTRegisterHandler<String>(docC, 'status');
  statusC.set('honest-fix');
  print('\nhonest peer C writes "honest-fix"');
  print('  C write clock = ${docC.hlc}  (real ~2026)');
  merge(docB, docC);
  print('  B after merging C: "${statusB.value}"  (honest 2026 < 2096, so it LOST)');
  print('  B.clock still ${docB.hlc}  (never comes back down)');
}

/// Merges [from] into [into], but REJECTS any change whose HLC physical time is
/// more than [maxDriftMs] ahead of the local wall clock. crdt_lf's own receive
/// path takes no maxDrift, so this app-level guard is where the clamp must live.
/// Returns the rejected (quarantined) changes.
List<Change> mergeWithDriftGuard(
  CRDTDocument into,
  CRDTDocument from,
  int maxDriftMs,
) {
  final now = DateTime.now().millisecondsSinceEpoch;
  final accepted = <Change>[];
  final rejected = <Change>[];
  for (final ch in from.exportChanges()) {
    if (ch.hlc.l - now > maxDriftMs) {
      rejected.add(ch);
    } else {
      accepted.add(ch);
    }
  }
  into.importChanges(accepted);
  return rejected;
}

/// Mitigation for the clock-skew bug: B refuses A's future-dated write.
void clockSkewMitigation() {
  const fastMs = 4000000000000; // peerA's skewed-fast clock (~year 2096)
  final docA = CRDTDocument(
    peerId: peerA,
    initialClock: HybridLogicalClock(l: fastMs, c: 0),
  );
  final statusA = CRDTRegisterHandler<String>(docA, 'status');
  final docB = CRDTDocument(peerId: peerB, documentId: docA.documentId);
  final statusB = CRDTRegisterHandler<String>(docB, 'status'); // correct clock

  statusA.set('from-A');
  statusB.set('from-B');

  // B pulls from A through the drift guard (tolerate at most 5 minutes ahead).
  const maxDriftMs = 5 * 60 * 1000;
  final rejected = mergeWithDriftGuard(docB, docA, maxDriftMs);

  final now = DateTime.now().millisecondsSinceEpoch;
  print('-- B merges A through a 5-minute drift guard --');
  print('  rejected ${rejected.length} change(s):');
  for (final ch in rejected) {
    final years = (ch.hlc.l - now) / (365.0 * 24 * 3600 * 1000);
    print('    ${peerTag(ch.author)} @ ${ch.hlc}  '
        '(~${years.toStringAsFixed(0)} years ahead)');
  }
  print('  B.status = ${statusB.value}   (kept its own write)');
  print('  B clock  = ${docB.hlc}   (stays honest -- not polluted)');

  print('\n-- the tradeoff: refusing the change means A and B DIVERGE --');
  print('  A.status = ${statusA.value}');
  print('  B.status = ${statusB.value}');
  print('  converged: ${statusA.value == statusB.value}');
}

/// Clock-skew pathology of LWW: peerA has a FAST clock (seeded far in the
/// future); peerB has a correct clock. They concurrently write the same field.
/// A wins purely because its clock is ahead -- even though B wrote LATER in real
/// time. "Higher HLC wins" is NOT "later in wall-clock time" when clocks differ.
void clockSkew() {
  const fastMs = 4000000000000; // peerA's skewed-fast clock (~year 2096)
  final docA = CRDTDocument(
    peerId: peerA,
    initialClock: HybridLogicalClock(l: fastMs, c: 0),
  );
  final statusA = CRDTRegisterHandler<String>(docA, 'status');
  final docB = CRDTDocument(peerId: peerB, documentId: docA.documentId);
  final statusB = CRDTRegisterHandler<String>(docB, 'status'); // correct clock

  // A writes first in real time...
  statusA.set('from-A');
  // ...then B writes LATER in real time. With honest clocks, B should win.
  statusB.set('from-B');

  print('-- the two concurrent writes --');
  for (final ch in [...docA.exportChanges(), ...docB.exportChanges()]) {
    print('  ${peerTag(ch.author)} @ ${ch.hlc}: '
        '${decodeRegister(ch.payloadBytes())}');
  }

  merge(docA, docB);
  merge(docB, docA);
  print('\n-- after exchange --');
  print('  A.status = ${statusA.value}');
  print('  B.status = ${statusB.value}');
  print('  winner   = ${statusA.value}  (B wrote later in real time, yet lost)');
  print('  B clock now: ${docB.hlc}  (dragged into the future by A)');
}

/// Same documentId, but each replica configures only its OWN handler:
/// A declares `status`, B declares `tags`. Do the changes converge, and can a
/// replica read a field whose handler it never instantiated?
void independentHandlers() {
  final docA = CRDTDocument(peerId: peerA);
  final statusA = CRDTRegisterHandler<String>(docA, 'status'); // A: only status
  final docB = CRDTDocument(peerId: peerB, documentId: docA.documentId);
  final tagsB = CRDTRegisterHandler<String>(docB, 'tags'); //     B: only tags

  statusA.set('done');
  tagsB.set('urgent, blocker');

  merge(docA, docB);
  merge(docB, docA);

  print('-- after exchange: the CHANGE LOG on each replica --');
  print('  docA: ${docA.exportChanges().length} changes');
  for (final ch in docA.exportChanges()) {
    print('    ${peerTag(ch.author)}: ${decodeRegister(ch.payloadBytes())}');
  }
  print('  docB: ${docB.exportChanges().length} changes');

  print('\n-- what each replica can READ (only its own handler exists) --');
  print('  A.status = ${statusA.value}');
  print('  B.tags   = ${tagsB.value}');

  print('\n-- now instantiate the MISSING handler on each, after the fact --');
  final tagsA = CRDTRegisterHandler<String>(docA, 'tags');
  final statusB = CRDTRegisterHandler<String>(docB, 'status');
  print('  A.tags   = ${tagsA.value}   (data was already in A\'s log)');
  print('  B.status = ${statusB.value}   (data was already in B\'s log)');
}

/// The trap: cram the whole frontmatter into ONE register as a JSON blob.
/// A writes only `status`, B writes only `tags` -- but each `set` replaces the
/// entire value, so whole-value LWW discards one blob and loses its field.
void blobRegisterClobber() {
  // Pin clocks so both writes share an HLC -> deterministic peerId tie-break.
  const pinnedMs = 4000000000000;
  final docA = CRDTDocument(
    peerId: peerA,
    initialClock: HybridLogicalClock(l: pinnedMs, c: 0),
  );
  final fmA = CRDTRegisterHandler<String>(docA, 'frontmatter');
  final docB = CRDTDocument(
    peerId: peerB,
    documentId: docA.documentId,
    initialClock: HybridLogicalClock(l: pinnedMs, c: 0),
  );
  final fmB = CRDTRegisterHandler<String>(docB, 'frontmatter');

  // Each peer serializes the WHOLE blob, touching only its own field.
  fmA.set('{"status":"done"}');
  fmB.set('{"tags":"urgent, blocker"}');
  print('-- before exchange (isolated) --');
  print('  A: ${fmA.value}');
  print('  B: ${fmB.value}');

  merge(docA, docB);
  merge(docB, docA);
  print('\n-- after exchange --');
  print('  A: ${fmA.value}');
  print('  B: ${fmB.value}');
  print('  converged: ${fmA.value == fmB.value}');

  final present = (jsonDecode(fmA.value!) as Map).keys.toSet();
  final all = {'status', 'tags'};
  print('  keys present: $present   LOST: ${all.difference(present)}');

  print('\n-- both writes are still in the log; only one blob is read --');
  for (final ch in docA.exportChanges()) {
    print('  ${peerTag(ch.author)} @ ${ch.hlc}: '
        '${decodeRegister(ch.payloadBytes())}');
  }
}

/// A sets `status`, B sets `tags`, concurrently -- neither touches the other's
/// field. Done two ways: (1) one handler per key, (2) one shared map handler.
void differentFieldsTwoWays() {
  print('### WAY 1: one handler per key (two registers) ###\n');
  {
    final docA = CRDTDocument(peerId: peerA);
    final statusA = CRDTRegisterHandler<String>(docA, 'status');
    final tagsA = CRDTRegisterHandler<String>(docA, 'tags');
    final docB = CRDTDocument(peerId: peerB, documentId: docA.documentId);
    final statusB = CRDTRegisterHandler<String>(docB, 'status');
    final tagsB = CRDTRegisterHandler<String>(docB, 'tags');

    statusA.set('done'); //          A writes only `status`
    tagsB.set('urgent, blocker'); //  B writes only `tags`
    merge(docA, docB);
    merge(docB, docA);

    print('  A: status=${statusA.value}  tags=${tagsA.value}');
    print('  B: status=${statusB.value}  tags=${tagsB.value}');
    print('  log (${docA.exportChanges().length} changes, separate handlers):');
    for (final ch in docA.exportChanges()) {
      print('    ${peerTag(ch.author)}: ${decodeRegister(ch.payloadBytes())}');
    }
  }

  print('\n### WAY 2: one shared handler for both keys (a map) ###\n');
  {
    final docA = CRDTDocument(peerId: peerA);
    final fmA = CRDTMapHandler<String>(docA, 'frontmatter');
    final docB = CRDTDocument(peerId: peerB, documentId: docA.documentId);
    final fmB = CRDTMapHandler<String>(docB, 'frontmatter');

    fmA.set('status', 'done'); //          A writes only `status`
    fmB.set('tags', 'urgent, blocker'); //  B writes only `tags`
    merge(docA, docB);
    merge(docB, docA);

    print('  A: ${fmA.value}');
    print('  B: ${fmB.value}');
    print('  log (${docA.exportChanges().length} changes, one handler '
        '"frontmatter"):');
    for (final ch in docA.exportChanges()) {
      print('    ${peerTag(ch.author)}: ${decodeMap(ch.payloadBytes())}');
    }
  }
}

/// Decodes a map `set` payload: envelope + key + value (delete carries no value).
String decodeMap(Uint8List body) {
  final c = _Cursor(body);
  c.string(); // handlerType
  final id = c.string();
  final kind = c.u8();
  final key = c.string();
  final value = kind == 1 ? '(deleted)' : c.string();
  return 'map[$id] $key = $value  [kind $kind]';
}

/// LWW registers: two peers write DIFFERENT fields concurrently, then exchange.
/// Different fields = different handlers, so there is no conflict -- both survive.
void lwwDifferentFields() {
  final docA = CRDTDocument(peerId: peerA);
  final statusA = CRDTRegisterHandler<String>(docA, 'status');
  final tagsA = CRDTRegisterHandler<String>(docA, 'tags');

  final docB = CRDTDocument(peerId: peerB, documentId: docA.documentId);
  final statusB = CRDTRegisterHandler<String>(docB, 'status');
  final tagsB = CRDTRegisterHandler<String>(docB, 'tags');

  // Concurrent writes to DIFFERENT fields, in isolation.
  statusA.set('done'); //          A touches only `status`
  tagsB.set('urgent, blocker'); //  B touches only `tags`
  print('-- before exchange (isolated) --');
  print('  A: status=${statusA.value}  tags=${tagsA.value}');
  print('  B: status=${statusB.value}  tags=${tagsB.value}');

  merge(docA, docB);
  merge(docB, docA);
  print('\n-- after exchange --');
  print('  A: status=${statusA.value}  tags=${tagsA.value}');
  print('  B: status=${statusB.value}  tags=${tagsB.value}');
  final converged =
      statusA.value == statusB.value && tagsA.value == tagsB.value;
  print('  converged: $converged');

  print('\n-- change log: ${docA.exportChanges().length} changes --');
  for (final ch in docA.exportChanges()) {
    print('  ${peerTag(ch.author)} @ ${ch.hlc}: '
        '${decodeRegister(ch.payloadBytes())}');
  }
}

/// Short A/B/C tag for a peerId, for readable output.
String peerTag(PeerId p) {
  if (p.toString() == peerA.toString()) return 'A';
  if (p.toString() == peerB.toString()) return 'B';
  if (p.toString() == peerC.toString()) return 'C';
  return p.toString().substring(0, 4);
}

/// LWW register: two peers write the SAME field to different values,
/// concurrently, then exchange. One value survives.
void lwwConcurrentWrite() {
  // Pin both clocks to the same instant so the two writes are genuinely
  // simultaneous (identical HLC). That forces the tie-break rule into the open;
  // without pinning, whichever write had the later wall-clock ms would just win.
  const pinnedMs = 4000000000000;
  final docA = CRDTDocument(
    peerId: peerA,
    initialClock: HybridLogicalClock(l: pinnedMs, c: 0),
  );
  final statusA = CRDTRegisterHandler<String>(docA, 'status');
  final docB = CRDTDocument(
    peerId: peerB,
    documentId: docA.documentId,
    initialClock: HybridLogicalClock(l: pinnedMs, c: 0),
  );
  final statusB = CRDTRegisterHandler<String>(docB, 'status');

  // Concurrent writes to the same key, in isolation.
  statusA.set('done');
  statusB.set('wip');
  print('-- before exchange (isolated) --');
  print('  A status : ${statusA.value}');
  print('  B status : ${statusB.value}');

  // Exchange both directions.
  merge(docA, docB);
  merge(docB, docA);
  print('\n-- after exchange --');
  print('  A status : ${statusA.value}');
  print('  B status : ${statusB.value}');
  print('  converged: ${statusA.value == statusB.value}');

  // Is the losing write tombstoned? No -- inspect the log. Both writes are
  // still present as live `set` operations; nothing marks 'done' as removed.
  final log = docA.exportChanges();
  print('\n-- change log: ${log.length} changes (no tombstones) --');
  for (final ch in log) {
    print('  ${peerTag(ch.author)} @ ${ch.hlc}: ${decodeRegister(ch.payloadBytes())}');
  }
}

/// Decodes a register `set` payload: envelope + uvarint-length-prefixed value
/// (JSON-encoded by the default codec, so a String shows with its quotes).
String decodeRegister(Uint8List body) {
  final c = _Cursor(body);
  final handlerType = c.string();
  final handlerId = c.string();
  final kind = c.u8();
  final value = c.string();
  return 'set $handlerId = $value  [kind $kind, $handlerType]';
}

/// peerA prunes its own history (snapshot + garbageCollect) BEFORE peerB has
/// received any of it; then peerB edits and peerA merges peerB's changes.
void snapshotGcScenario() {
  final docA = CRDTDocument(peerId: peerA);
  final textA = CRDTFugueTextHandler(docA, 'text1');
  final docB = CRDTDocument(peerId: peerB, documentId: docA.documentId);
  final textB = CRDTFugueTextHandler(docB, 'text1');

  // 1. peerA makes a bunch of changes. peerB receives NONE of them.
  textA.insert(0, 'Alpha');
  textA.insert(5, ' Bravo');
  textA.insert(11, ' Charlie');
  print('-- peerA after edits (peerB has seen nothing) --');
  print('  A value      : "${textA.value}"');
  print('  A change log : ${docA.exportChanges().length} changes');

  // 2. Snapshot, but KEEP history.
  docA.takeSnapshot(pruneHistory: false);
  print('\n-- peerA takeSnapshot(pruneHistory: false) --');
  print(
    '  A change log : ${docA.exportChanges().length} changes (still there)',
  );

  // 3. garbageCollect using peerA's OWN frontier as the stability frontier.
  //    peerB has acknowledged nothing, but this frontier ignores that, so all
  //    of peerA's history up to the snapshot is pruned.
  docA.garbageCollect(docA.getVersionVector());
  summary('A', textA);
  print('\n-- peerA garbageCollect(own frontier) --');
  print('  A value      : "${textA.value}"  (preserved by the snapshot)');
  print(
    '  A change log : ${docA.exportChanges().length} changes (history pruned!)',
  );

  // 4. peerB -- which never received A's edits -- makes its own edits.
  textB.insert(0, 'Zulu');
  print('\n-- peerB edits, still ignorant of A --');
  print('  B value      : "${textB.value}"');
  print('  B change log : ${docB.exportChanges().length} changes');

  // 5. THE QUESTION: peerA merges peerB's changes.
  final applied = docA.importChanges(docB.exportChanges());
  print("\n-- peerA merges peerB's changes --");
  print('  changes applied : $applied');
  print('  A value         : "${textA.value}"');

  // 6. Reverse direction: can peerB catch up on A via change-merge? A's history
  //    is gone, so exportChanges cannot carry A's original edits.
  final offer = docA.exportChanges();
  docB.importChanges(offer);
  print('\n-- peerB pulls from peerA via change-merge (delta sync) --');
  print('  A can offer  : ${offer.length} changes');
  print('  B value      : "${textB.value}"');
  print('  converged    : ${textA.value == textB.value}');

  // ===== Correct usage: stability frontier = intersection of ALL peers =====
  // garbageCollect does not know about other peers; the CALLER must compute the
  // minimum common version and pass it in. Here peerB has acknowledged nothing,
  // so its version vector is empty, the intersection is empty, and GC becomes a
  // no-op -- history is preserved and both directions can still delta-sync.
  print('\n\n=== Correct usage: garbageCollect(intersection of all peers) ===\n');

  final docA2 = CRDTDocument(peerId: peerA);
  final textA2 = CRDTFugueTextHandler(docA2, 'text1');
  final docB2 = CRDTDocument(peerId: peerB, documentId: docA2.documentId);
  final textB2 = CRDTFugueTextHandler(docB2, 'text1');

  textA2.insert(0, 'Alpha Bravo Charlie');
  docA2.takeSnapshot(pruneHistory: false);

  // The frontier every peer has in common. docB2.getVersionVector() is what
  // peerB has actually acknowledged (empty), so the intersection is empty.
  final stability = VersionVector.intersection([
    docA2.getVersionVector(),
    docB2.getVersionVector(),
  ]);
  docA2.garbageCollect(stability);
  print('  stability frontier empty : ${stability.isEmpty}');
  print(
    '  A change log after GC    : ${docA2.exportChanges().length} changes (preserved)',
  );

  // Now peerB edits, and delta-sync works in BOTH directions.
  textB2.insert(0, 'Zulu');
  merge(docA2, docB2);
  merge(docB2, docA2);
  print('  A value   : "${textA2.value}"');
  print('  B value   : "${textB2.value}"');
  print('  converged : ${textA2.value == textB2.value}');
}

/// OR-Set (observed-remove set): concurrent add vs. remove of the same tag.
///
/// `add(v)` mints a unique tag (peerId + hlc) per call; `remove(v)` tomb-stones
/// only the tags the removing replica has ALREADY OBSERVED. A value is present
/// iff it has at least one non-tomb-stoned tag.
void orSetScenario() {
  print("=== OR-Set case 1: B removes WITHOUT observing A's add ===\n");

  final docA = CRDTDocument(peerId: peerA);
  final setA = CRDTORSetHandler<String>(docA, 'tags');
  final docB = CRDTDocument(peerId: peerB, documentId: docA.documentId);
  final setB = CRDTORSetHandler<String>(docB, 'tags');

  // Both peers add 'urgent' concurrently, in isolation. Each add mints its OWN
  // unique tag, so 'urgent' ends up backed by TWO independent tags.
  setA.add('urgent');
  setB.add('urgent');
  print('-- after concurrent adds (isolated) --');
  setSummary('A', setA);
  setSummary('B', setB);

  // B removes 'urgent'. It tomb-stones only the tags B has observed -- and B has
  // not seen A's add yet, so only B's own tag is tomb-stoned.
  setB.remove('urgent');
  print("\n-- after B removes (still isolated; only B's tag observed) --");
  setSummary('A', setA);
  setSummary('B', setB);

  merge(docA, docB);
  merge(docB, docA);
  print('\n-- after bidirectional merge --');
  setSummary('A', setA);
  setSummary('B', setB);
  print(
    "  => 'urgent' SURVIVES: A's concurrent add was never observed by "
    "B's remove.",
  );
  print('  converged: ${sameSet(setA.value, setB.value)}');

  // ----- Contrast: same edits, but B observes A's add before removing -----
  print("\n\n=== OR-Set case 2: B removes AFTER observing A's add ===\n");

  final docA2 = CRDTDocument(peerId: peerA);
  final setA2 = CRDTORSetHandler<String>(docA2, 'tags');
  final docB2 = CRDTDocument(peerId: peerB, documentId: docA2.documentId);
  final setB2 = CRDTORSetHandler<String>(docB2, 'tags');

  setA2.add('urgent');
  setB2.add('urgent');
  setB2.remove('urgent');
  merge(docA2, docB2);
  merge(docB2, docA2); // now BOTH tags are observed everywhere
  print('-- after concurrent adds + merge (both tags observed) --');
  setSummary('A', setA2);
  setSummary('B', setB2);

  print('  converged: ${sameSet(setA2.value, setB2.value)}');
}

/// One-line status of an OR-Set replica.
void setSummary(String label, CRDTORSetHandler<String> set) {
  print('  $label: ${set.value}');
}

/// Content equality for two string sets.
bool sameSet(Set<String> a, Set<String> b) =>
    a.length == b.length && a.containsAll(b);

/// Text-handler conflict walkthrough from earlier, kept for reference.
void textScenario() {
  // A logical document with two peers = two CRDTDocument *replicas* that share
  // the same documentId but have distinct peerIds. Each replica owns a handler
  // with the SAME handler id ('text1') so edits target the same logical text.
  // Pin BOTH replicas to the same logical clock, set far enough in the future
  // that the wall clock never overtakes it. localEvent() then keeps `l` fixed
  // and only bumps the counter, so every change on both peers is stamped at the
  // SAME millisecond -- the only differentiator becomes the peerId.
  const pinnedMs = 4000000000000; // ~ year 2096, safely beyond DateTime.now()
  final docA = CRDTDocument(
    peerId: peerA,
    initialClock: HybridLogicalClock(l: pinnedMs, c: 0),
  );
  final textA = CRDTFugueTextHandler(docA, 'text1');

  final docB = CRDTDocument(
    peerId: peerB,
    documentId: docA.documentId,
    initialClock: HybridLogicalClock(l: pinnedMs, c: 0),
  );
  final textB = CRDTFugueTextHandler(docB, 'text1');

  // 1. Shared base: A types it, B pulls it in, so both agree before diverging.
  textA.insert(0, 'Hello world');
  merge(docB, docA);
  print('-- shared base --');
  summary('A', textA);
  summary('B', textB);

  // 2. Both peers insert at the SAME position, IN ISOLATION -- a true conflict.
  //    Same anchor, same millisecond: only the peerId breaks the tie.
  textA.insert(11, 'AAA'); //   A: "Hello worldAAA"
  textB.insert(11, 'BBB'); //   B: "Hello worldBBB"
  print('\n-- isolated concurrent edits at the same spot (not yet merged) --');
  summary('A', textA);
  summary('B', textB);

  // interior inserts
  textA.insert(6, 'beaut');
  textB.insert(6, 'iful ');
  print('\n-- isolated concurrent edits at the same spot (not yet merged) --');
  merge(docB, docA);
  merge(docA, docB);
  print('\n-- After interior inserts and merge --');
  summary('A', textA);
  summary('B', textB);

  // conflicting edit/delete
  textA.insert(19, '!');
  textB.delete(16, 5);
  print(
    '\n-- isolated concurrent edits/deletes at the same spot (not yet merged) --',
  );
  merge(docB, docA);
  merge(docA, docB);
  print('\n-- After conflicting edit/delete and merge --');
  summary('A', textA);
  summary('B', textB);
  // 3. Merge both directions. importChanges is idempotent and causal, so order
  //    and re-sending already-seen changes don't matter.
  merge(docA, docB);
  merge(docB, docA);
  print('\n-- after bidirectional merge --');
  summary('A', textA);
  summary('B', textB);
  print('\nconverged: ${textA.value == textB.value}');

  // 4. Full history of the merged replica — note changes from BOTH peers.
  print('');
  dump(docA, textA);
}

/// Pulls every change from [from] into [into].
///
/// [CRDTDocument.importChanges] skips already-seen changes and topologically
/// sorts by dependencies, so calling this repeatedly / in any order is safe.
void merge(CRDTDocument into, CRDTDocument from) {
  into.importChanges(from.exportChanges());
}

/// One-line status of a replica's text.
void summary(String label, CRDTFugueTextHandler text) {
  print('  $label: "${text.value}"  (len ${text.length})');
}

/// Friendly, read-only snapshot of a document and one text handler.
void dump(CRDTDocument doc, CRDTFugueTextHandler text) {
  print('== Document ==');
  print('  peerId     : ${doc.peerId}');
  print('  documentId : ${doc.documentId}');
  print('  isEmpty    : ${doc.isEmpty}');
  print('  hlc        : ${doc.hlc}');
  print('  version    : ${doc.version}');

  print('== Text handler (${text.id}) ==');
  print('  value  : "${text.value}"');
  print('  length : ${text.length}');

  final changes = doc.exportChanges();
  print('== Change history (${changes.length}) ==');
  for (final change in changes) {
    print('  - $change');
    print(decodePayload(change.payloadBytes(), indent: '      '));
    print(hexDump(change.payloadBytes(), indent: '      '));
  }
}

/// Decodes a Fugue-text operation payload into a labeled, human-readable form.
///
/// Mirrors the crdt_lf binary codecs: an [OperationEnvelopeCodec] header
/// (handlerType, handlerId, kind byte) followed by a kind-specific body built
/// from [FugueElementID]s and length-prefixed UTF-8 text.
String decodePayload(Uint8List body, {String indent = ''}) {
  final c = _Cursor(body);
  final out = StringBuffer();

  // Envelope.
  final handlerType = c.string();
  final handlerId = c.string();
  final kind = c.u8();
  const kindNames = {0: 'insert', 1: 'delete', 2: 'update', 3: 'move'};
  final kindName = kindNames[kind] ?? 'unknown($kind)';

  out.writeln('${indent}handler : $handlerType');
  out.writeln('${indent}id      : $handlerId');
  out.writeln('${indent}kind    : $kindName');

  // Body.
  switch (kind) {
    case 0: // insert
      out.writeln('${indent}left    : ${c.elementId()}');
      out.writeln('${indent}right   : ${c.elementId()}');
      final count = c.uvarint();
      out.writeln('${indent}items   : $count');
      for (var i = 0; i < count; i++) {
        final id = c.elementId();
        out.writeln('$indent  [$i] insert "${c.string()}" at id=$id');
      }
    case 1: // delete
      final count = c.uvarint();
      out.writeln('${indent}items   : $count');
      for (var i = 0; i < count; i++) {
        out.writeln('$indent  [$i] delete id=${c.elementId()}');
      }
    case 2: // update
      final count = c.uvarint();
      out.writeln('${indent}items   : $count');
      for (var i = 0; i < count; i++) {
        final id = c.elementId();
        final newId = c.elementId();
        out.writeln('$indent  [$i] update id=$id -> $newId "${c.string()}"');
      }
    default:
      out.writeln('$indent(no decoder for kind $kind)');
  }
  return out.toString().trimRight();
}

/// A forward-only reader over a byte buffer, matching crdt_lf's binary codecs.
class _Cursor {
  _Cursor(this.bytes);

  final Uint8List bytes;
  int offset = 0;

  /// Reads one unsigned byte.
  int u8() => bytes[offset++];

  /// Reads an unsigned LEB128 varint.
  int uvarint() {
    var result = 0;
    var multiplier = 1;
    while (true) {
      final b = bytes[offset++];
      result += (b & 0x7f) * multiplier;
      if (b & 0x80 == 0) break;
      multiplier *= 128;
    }
    return result;
  }

  /// Reads a uvarint length followed by that many UTF-8 bytes.
  String string() {
    final len = uvarint();
    final s = utf8.decode(bytes.sublist(offset, offset + len));
    offset += len;
    return s;
  }

  /// Reads a FugueElementID: flag byte, then (if present) 16-byte PeerId and
  /// a uvarint counter. Renders as `peerId@counter`, or `null` when empty.
  String elementId() {
    final flag = u8();
    if (flag == 0) return 'null';
    final peer = _peerIdString(offset);
    offset += 16;
    return '$peer@${uvarint()}';
  }

  /// Formats 16 bytes at [at] as a canonical UUID string (a PeerId).
  String _peerIdString(int at) {
    final hex = [
      for (var i = 0; i < 16; i++)
        bytes[at + i].toRadixString(16).padLeft(2, '0'),
    ].join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }
}

/// Renders [bytes] as a classic hex dump: offset, 16 hex columns, ASCII gutter.
String hexDump(Uint8List bytes, {String indent = ''}) {
  if (bytes.isEmpty) return '$indent(empty)';

  final out = StringBuffer();
  for (var offset = 0; offset < bytes.length; offset += 16) {
    final row = bytes.sublist(offset, min(offset + 16, bytes.length));

    final hex = StringBuffer();
    for (var i = 0; i < 16; i++) {
      if (i < row.length) {
        hex.write(row[i].toRadixString(16).padLeft(2, '0'));
      } else {
        hex.write('  ');
      }
      hex.write(i == 7 ? '  ' : ' ');
    }

    final ascii = row
        .map((b) => (b >= 0x20 && b <= 0x7e) ? String.fromCharCode(b) : '.')
        .join();

    out.writeln(
      '$indent${offset.toRadixString(16).padLeft(8, '0')}  '
      '${hex.toString().trimRight().padRight(48)}  |$ascii|',
    );
  }
  return out.toString().trimRight();
}
