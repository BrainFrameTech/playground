/// Tier 2 — concurrent `change()` across surrogate and grapheme boundaries.
///
/// This is where the remaining risk lives. `change()` runs a **code-unit**
/// Myers diff, so editing `a😀b` into `a😃b` deletes and re-inserts only the
/// LOW surrogate: the emoji ends up assembled from two code units that belong
/// to different operations. In `CRDTFugueTextHandler` those are two independent
/// tree elements with no constraint keeping them adjacent, so a concurrent edit
/// can in principle land between them.
///
/// With genuine concurrent edits there is no single correct output text, so
/// these tests assert *invariants* rather than exact content:
///
///   HARD (a text CRDT must never violate these):
///     1. both replicas converge, and delivery is idempotent
///     2. the result is well-formed UTF-16 — no lone surrogates
///     3. no NOVEL code point appears: a high surrogate from `😀` pairing with
///        a low surrogate from `😃` yields a character nobody ever typed
///
///   ADVISORY (grapheme-level integrity, reported separately because partial
///   clusters can be a legitimate merge outcome).
library;

import 'package:characters/characters.dart';
import 'package:test/test.dart';

import 'support/unicode_corpus.dart';
import 'support/unicode_support.dart';

class ConcurrentCase {
  ConcurrentCase({
    required this.name,
    required this.base,
    required this.editA,
    required this.editB,
    required this.why,
  });

  final String name;
  final String base;
  final void Function(TextFacade) editA;
  final void Function(TextFacade) editB;
  final String why;
}

final List<ConcurrentCase> concurrentCases = <ConcurrentCase>[
  ConcurrentCase(
    name: 'both-replace-low-surrogate-of-same-emoji',
    base: 'a${grin}b',
    editA: (t) => t.change('a${smile}b'),
    editB: (t) => t.change('a${astralCjk}b'),
    why: 'A rewrites the low surrogate to DE03 while B rewrites the whole pair '
        'to D840 DC00. A surviving D83D next to a surviving DC00 would be '
        'U+1F400 RAT — a character neither replica typed.',
  ),
  ConcurrentCase(
    name: 'shared-low-surrogate-collision',
    base: 'x${astralCjk}y',
    editA: (t) => t.change('x${mathA}y'),
    editB: (t) => t.change('x${grin}y'),
    why: 'astralCjk (D840 DC00) and mathA (D835 DC00) share their LOW '
        'surrogate, so the diffs edit opposite halves of the same pair.',
  ),
  ConcurrentCase(
    name: 'insert-adjacent-while-other-replaces-emoji',
    base: 'a${grin}b',
    editA: (t) => t.change('a${grin}Xb'),
    editB: (t) => t.change('a${smile}b'),
    why: "A's insertion anchors next to the pair while B is deleting and "
        'reinserting half of it.',
  ),
  ConcurrentCase(
    name: 'both-insert-between-two-emoji',
    base: '$grin$grin',
    editA: (t) => t.change('${grin}X$grin'),
    editB: (t) => t.change('${grin}Y$grin'),
    why: 'the shared insertion point is also a pair boundary; Fugue must not '
        'interleave X and Y into the middle of either pair.',
  ),
  ConcurrentCase(
    name: 'delete-emoji-while-other-modifies-it',
    base: 'a${grin}b',
    editA: (t) => t.change('ab'),
    editB: (t) => t.change('a${smile}b'),
    why: 'A removes both halves; B removes one and adds a replacement. The '
        'union of those deletes must not leave a stray half.',
  ),
  ConcurrentCase(
    name: 'concurrent-reorder-of-astral-chars',
    base: '${grin}X$mathA',
    editA: (t) => t.change('$mathA${grin}X'),
    editB: (t) => t.change('X$mathA$grin'),
    why: 'both replicas shuffle whole pairs in different directions.',
  ),
  ConcurrentCase(
    name: 'combining-mark-vs-base-edit',
    base: 'caf$eAcuteNfd',
    editA: (t) => t.change('caf$eAcuteNfc'),
    editB: (t) => t.change('caf${eAcuteNfd}s'),
    why: 'A collapses base+mark into one code point while B appends after the '
        'mark.',
  ),
  ConcurrentCase(
    name: 'zwj-family-concurrent-edit',
    base: familyGirl,
    editA: (t) => t.change(familyBoy),
    editB: (t) => t.change(man),
    why: 'A swaps the last ZWJ member; B truncates the sequence.',
  ),
  ConcurrentCase(
    name: 'flag-adjacency',
    base: flagDk,
    editA: (t) => t.change(flagDe),
    editB: (t) => t.change('${flagDk}z'),
    why: 'regional indicators render by adjacency, so a merge can produce a '
        'flag that is code-unit-valid but semantically invented.',
  ),
];

void main() {
  handlers.forEach((handlerName, factory) {
    group('$handlerName — hard invariants', () {
      for (final c in concurrentCases) {
        test(c.name, () {
          final m = mergeConcurrent(
            base: c.base,
            editA: c.editA,
            editB: c.editB,
            factory: factory,
          );

          printOnFailure(_report(c, m));

          expect(
            m.aAfterMerge,
            m.bAfterMerge,
            reason: 'replicas did not converge',
          );
          expect(
            m.bAfterDuplicate,
            m.bAfterMerge,
            reason: 'redelivering the same changes altered the state '
                '(importChanges is not idempotent)',
          );
          expect(
            loneSurrogates(m.bAfterMerge),
            isEmpty,
            reason: 'merge produced ill-formed UTF-16 — a surrogate pair was '
                'torn apart by concurrent edits',
          );
          expect(
            novelCodePoints(m.bAfterMerge, m.inputs),
            isEmpty,
            reason: 'merge SYNTHESIZED code points that appear in neither '
                "replica's text — surrogate halves were recombined across "
                'operations',
          );
        });
      }
    });

    group('$handlerName — grapheme integrity (advisory)', () {
      for (final c in concurrentCases) {
        test(c.name, () {
          final m = mergeConcurrent(
            base: c.base,
            editA: c.editA,
            editB: c.editB,
            factory: factory,
          );

          printOnFailure(_report(c, m));

          expect(
            orphanZwj(m.bAfterMerge),
            isEmpty,
            reason: 'merge left a dangling ZERO WIDTH JOINER',
          );
          expect(
            novelGraphemes(m.bAfterMerge, m.inputs),
            isEmpty,
            reason: 'merge produced grapheme clusters present in no input; '
                'may be a legitimate partial cluster — read the dump above',
          );
        });
      }
    });

    group('$handlerName — code-unit API surface', () {
      test('inserting between surrogate halves is reachable via insert()', () {
        // Both handlers index by UTF-16 code unit, so index 1 of a
        // single-emoji document sits *inside* the surrogate pair. Nothing in
        // the API signature prevents a caller (or a cursor computed from a
        // code-unit offset) from asking for it. This test records what happens.
        final r = replicaWith(grin, factory);
        r.text.insert(1, 'X');

        final replicated = viaChanges(r.doc, factory);
        printOnFailure('''
after insert(1, "X") into a lone emoji:
  local      : "${r.value}" ${hex(r.value)}
  replicated : "$replicated" ${hex(replicated)}
  lone surrogates at: ${loneSurrogates(replicated)}''');

        expect(
          replicated,
          r.value,
          reason: 'local and replicated state disagree',
        );
        expect(
          loneSurrogates(replicated),
          isEmpty,
          reason: 'insert() at a code-unit index inside a surrogate pair tore '
              'the pair, producing ill-formed UTF-16. The handler indexes by '
              'code unit with no pair guard.',
        );
      });

      test('deleting one half of a pair is reachable via delete()', () {
        final r = replicaWith('a${grin}b', factory);
        r.text.delete(2, 1); // the low surrogate only

        final replicated = viaChanges(r.doc, factory);
        printOnFailure('''
after delete(2, 1) on "a${grin}b":
  local      : "${r.value}" ${hex(r.value)}
  replicated : "$replicated" ${hex(replicated)}''');

        expect(replicated, r.value);
        expect(
          loneSurrogates(replicated),
          isEmpty,
          reason: 'delete() removed one half of a surrogate pair, leaving '
              'ill-formed UTF-16',
        );
      });
    });
  });
}

String _report(ConcurrentCase c, MergeOutcome m) => '''
case   : ${c.name}
probing: ${c.why}
  base            : "${m.base}" ${hex(m.base)}
  A local         : "${m.aBeforeMerge}" ${hex(m.aBeforeMerge)}
  B local         : "${m.bBeforeMerge}" ${hex(m.bBeforeMerge)}
  A after merge   : "${m.aAfterMerge}" ${hex(m.aAfterMerge)}
  B after merge   : "${m.bAfterMerge}" ${hex(m.bAfterMerge)}
  B after redeliver: "${m.bAfterDuplicate}" ${hex(m.bAfterDuplicate)}
  converged       : ${m.converged}
  well-formed     : ${isWellFormedUtf16(m.bAfterMerge)}
  lone surrogates : ${loneSurrogates(m.bAfterMerge)}
  novel codepoints: ${novelCodePoints(m.bAfterMerge, m.inputs).map((cp) => 'U+${cp.toRadixString(16).toUpperCase()}').toList()}
  orphan ZWJ      : ${orphanZwj(m.bAfterMerge)}
  graphemes       : ${m.bAfterMerge.characters.toList()}
  novel graphemes : ${novelGraphemes(m.bAfterMerge, m.inputs).toList()}''';
