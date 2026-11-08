/// Tier 4 — `change()` inside vs. outside `runInTransaction`.
///
/// The `change()` docstring recommends wrapping the call in
/// `CRDTDocument.runInTransaction` "for better performance and atomicity". That
/// matters for correctness, not just speed: `CRDTFugueTextHandler.insert`
/// resolves its anchor with `originBefore(index)` against the *current* tree,
/// and `change()` emits several insert/delete calls whose indices assume every
/// earlier operation in the same diff has already landed. If a transaction
/// defers visibility of intermediate state, later segments resolve against a
/// stale tree and land in the wrong place.
///
/// Non-BMP text is the sharp end of this: every astral character doubles the
/// code-unit count and multiplies the number of diff segments, so a
/// multi-segment edit over emoji is the most likely place for the two paths to
/// disagree.
library;

import 'package:test/test.dart';

import 'support/unicode_corpus.dart';
import 'support/unicode_support.dart';

/// Edits chosen to produce several interleaved insert/remove segments rather
/// than one contiguous replacement.
const List<({String name, String from, String to})> multiSegmentEdits = [
  (
    name: 'ascii-multi-segment',
    from: 'the quick brown fox',
    to: 'a quick red fox jumps',
  ),
  (
    name: 'astral-multi-segment',
    from: 'a${grin}b${astralCjk}c',
    to: 'X${smile}b${mathA}cY',
  ),
  (
    name: 'astral-reorder-multi-segment',
    from: '$grin$astralCjk$mathA',
    to: '$mathA$grin$astralCjk',
  ),
  (
    name: 'mixed-clusters',
    from: '$familyGirl caf$eAcuteNfd $flagDk',
    to: '$familyBoy caf$eAcuteNfc $flagDe!',
  ),
  (
    name: 'interleaved-single-units',
    from: 'a${grin}b${grin}c${grin}d',
    to: 'a${smile}b${smile}c${smile}d',
  ),
];

void main() {
  handlers.forEach((handlerName, factory) {
    group(handlerName, () {
      for (final e in multiSegmentEdits) {
        test('${e.name}: transaction and non-transaction paths agree', () {
          final direct = replicaWith(e.from, factory);
          direct.text.change(e.to);

          final txn = replicaWith(e.from, factory);
          txn.doc.runInTransaction(() => txn.text.change(e.to));

          printOnFailure('''
  from        : "${e.from}" ${hex(e.from)}
  to          : "${e.to}" ${hex(e.to)}
  direct local: "${direct.value}" ${hex(direct.value)}
  txn local   : "${txn.value}" ${hex(txn.value)}''');

          expect(
            direct.value,
            e.to,
            reason: 'change() outside a transaction produced the wrong text',
          );
          expect(
            txn.value,
            e.to,
            reason: 'change() inside runInTransaction produced the wrong text. '
                'If the direct path passed and this failed, the operations in '
                'one change() are resolving their indices against pre-'
                'transaction state.',
          );
          expect(
            viaChanges(txn.doc, factory),
            e.to,
            reason: 'transactional change() did not survive replication',
          );
          expect(
            viaSnapshot(txn.doc, factory),
            e.to,
            reason: 'transactional change() did not survive snapshot/restore',
          );
        });
      }

      test('several change() calls in one transaction compose', () {
        final r = replicaWith('a${grin}b', factory);
        r.doc.runInTransaction(() {
          r.text
            ..change('a${smile}b')
            ..change('a${smile}b$mathA')
            ..change('$familyGirl a${smile}b$mathA');
        });

        const expected = '$familyGirl a${smile}b$mathA';
        expect(r.value, expected, reason: 'got ${hex(r.value)}');
        expect(viaChanges(r.doc, factory), expected);
        expect(viaSnapshot(r.doc, factory), expected);
      });

      test('transactional change() converges with a concurrent edit', () {
        final m = mergeConcurrent(
          base: 'a${grin}b',
          editA: (t) => t.change('a${smile}b'),
          editB: (t) => t.change('a${grin}Zb'),
          factory: factory,
        );

        printOnFailure('A: ${hex(m.aAfterMerge)}  B: ${hex(m.bAfterMerge)}');
        expect(m.converged, isTrue, reason: 'replicas did not converge');
        expect(loneSurrogates(m.bAfterMerge), isEmpty);
      });
    });
  });
}
