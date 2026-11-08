/// Tier 5 — minimal, Unicode-free reductions of bugs the Unicode suite found.
///
/// Two of the failures surfaced by tiers 1–4 are not Unicode bugs at all. They
/// were *found* by non-BMP tests only because astral characters double the
/// code-unit count and so multiply the number of diff segments `change()`
/// emits — which made the underlying positional defects far more likely to be
/// hit. Both reduce to plain ASCII.
///
/// Keeping the reductions here separates concerns: if these fail and the tier
/// 1–4 Unicode tests fail, fix these first — the Unicode failures may just be
/// downstream. All tests in this file assert CORRECT behaviour, so they fail
/// against crdt_lf 3.4.2 until the library is fixed.
library;

import 'package:crdt_lf/crdt_lf.dart';
import 'package:test/test.dart';

void main() {
  // -------------------------------------------------------------------------
  group('BUG 1 — Fugue misorders an insert placed before a prior insert', () {
    // `CRDTFugueTextHandler.insert(index, …)` anchors via
    // `originBefore(index)` / `nodeAfter(...)`. When the element currently at
    // `index` was itself added by an earlier *local* insert, the new text is
    // anchored to the right of it instead of to its left, so it lands after
    // the text it was supposed to precede.
    //
    // `change()` hits this whenever a diff prepends to a region that a
    // previous `change()` already inserted — i.e. ordinary typing at the start
    // of a line. No Unicode, no concurrency, no serialization involved: the
    // originating replica's own in-memory value is already wrong.

    test('three sequential insert(0) calls (minimal repro)', () {
      final t = CRDTFugueTextHandler(CRDTDocument(), 't');
      t.insert(0, 'abc');
      expect(t.value, 'abc');

      t.insert(0, 'Z');
      expect(t.value, 'Zabc', reason: 'first prepend is fine');

      t.insert(0, 'QQ');
      expect(
        t.value,
        'QQZabc',
        reason: 'second prepend landed after "Z" instead of before it',
      );
    });

    test('a chain of prepends scrambles badly', () {
      final t = CRDTFugueTextHandler(CRDTDocument(), 't');
      for (final c in <String>['a', 'b', 'c', 'd', 'e']) {
        t.insert(0, c);
      }
      expect(t.value, 'edcba');
    });

    test('not specific to index 0 — any insert before a prior insert', () {
      final t = CRDTFugueTextHandler(CRDTDocument(), 't');
      t.insert(0, 'abc');
      t.insert(1, 'Z');
      expect(t.value, 'aZbc');

      t.insert(1, 'QQ');
      expect(t.value, 'aQQZbc');
    });

    test('reachable through change() alone', () {
      final t = CRDTFugueTextHandler(CRDTDocument(), 't');
      t.insert(0, 'abc');
      t.change('Xbc');
      t.change('QXbc');
      expect(t.value, 'QXbc');
    });

    test('the wrong order is what gets replicated', () {
      // Confirms this is a state bug, not a wire-format bug: the replica
      // faithfully reproduces the originating replica's already-wrong value.
      final d = CRDTDocument();
      final t = CRDTFugueTextHandler(d, 't');
      t.insert(0, 'abc');
      t.change('Xbc');
      t.change('QXbc');

      final b = CRDTDocument(documentId: d.documentId);
      final tb = CRDTFugueTextHandler(b, 't');
      b.importChanges(d.exportChanges());

      expect(tb.value, t.value, reason: 'replication itself is faithful');
      expect(t.value, 'QXbc', reason: 'the replicated value is wrong');
    });

    test('CRDTFugueListHandler has the same defect', () {
      // Locates the bug below the text handler, in the shared Fugue sequence
      // layer — so a fix belongs there, not in the text codec.
      final l = CRDTFugueListHandler<String>(CRDTDocument(), 'l');
      l.insert(0, 'a');
      l.insert(0, 'b');
      l.insert(0, 'c');
      expect(l.value, <String>['c', 'b', 'a']);
    });

    test('CRDTTextHandler is NOT affected', () {
      final t = CRDTTextHandler(CRDTDocument(), 't');
      t.insert(0, 'abc');
      t.insert(0, 'Z');
      t.insert(0, 'QQ');
      expect(t.value, 'QQZabc');
    });
  });

  // -------------------------------------------------------------------------
  group('BUG 2 — CRDTTextHandler.compound throws on a leftward insert', () {
    // `_isContiguousInsertion` (text/handler.dart:326) is
    //     accumulator.index + accumulator.text.length >= current.index
    // which has no LOWER bound: it is also satisfied when `current.index` is
    // smaller than `accumulator.index`. `compound` then evaluates
    // `accumulator.text.substring(0, current.index - accumulator.index)`
    // (text/handler.dart:267) with a negative end and throws RangeError.
    //
    // This fires during transaction commit, so it takes down the whole
    // transaction — and `change()`'s own docstring recommends wrapping calls in
    // `runInTransaction`.

    test('two inserts in one transaction, right then left', () {
      final d = CRDTDocument();
      final t = CRDTTextHandler(d, 't');
      t.insert(0, 'abc');

      d.runInTransaction(() {
        t
          ..insert(2, 'M')
          ..insert(0, 'Q');
      });

      expect(t.value, 'QabMc');
    });

    test('two change() calls in one transaction', () {
      final d = CRDTDocument();
      final t = CRDTTextHandler(d, 't');
      t.insert(0, 'abc');

      d.runInTransaction(() {
        t
          ..change('abcZ')
          ..change('Qabc Z');
      });

      expect(t.value, 'Qabc Z');
    });

    test('the identical sequence outside a transaction is correct', () {
      // Proves the diff and the operations are right; only the compaction path
      // run at commit time is broken.
      final d = CRDTDocument();
      final t = CRDTTextHandler(d, 't');
      t.insert(0, 'abc');
      t
        ..change('abcZ')
        ..change('Qabc Z');

      expect(t.value, 'Qabc Z');
    });

    test('CRDTFugueTextHandler does not throw here', () {
      final d = CRDTDocument();
      final t = CRDTFugueTextHandler(d, 't');
      t.insert(0, 'abc');

      expect(
        () => d.runInTransaction(() {
          t
            ..insert(2, 'M')
            ..insert(0, 'Q');
        }),
        returnsNormally,
      );
    });
  });
}
