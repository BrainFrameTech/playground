/// Tier 1 — corpus round-trip through `change()`.
///
/// For every `(from, to)` pair: build a document holding `from`, call
/// `change(to)`, then assert the value is exactly `to` on
///   (a) the originating replica,
///   (b) a fresh replica built from exported changes, and
///   (c) a replica rebuilt from snapshot bytes.
///
/// Assertions are code-unit-exact equality against the expected text, not
/// "the replicas agree" — convergence to identical garbage was the failure
/// mode of the original bug.
library;

import 'package:characters/characters.dart';
import 'package:test/test.dart';

import 'support/unicode_corpus.dart';
import 'support/unicode_support.dart';

void main() {
  handlers.forEach((handlerName, factory) {
    group(handlerName, () {
      for (final c in corpus) {
        test(c.name, () {
          final r = replicaWith(c.from, factory);
          expect(
            r.value,
            c.from,
            reason: 'setup failed before change() was even called: '
                'insert(0, from) produced ${hex(r.value)}',
          );

          r.text.change(c.to);

          expect(r.value, c.to, reason: _detail(c, 'local (in-memory)', r.value));

          final replicated = viaChanges(r.doc, factory);
          expect(
            replicated,
            c.to,
            reason: _detail(c, 'replica built from exported changes', replicated),
          );

          final restored = viaSnapshot(r.doc, factory);
          expect(
            restored,
            c.to,
            reason: _detail(c, 'replica rebuilt from snapshot bytes', restored),
          );
        });
      }

      test('repeated change() to the same value is a no-op', () {
        final r = replicaWith('a${grin}b', factory);
        r.text.change('a${smile}b');
        final afterFirst = r.doc.exportChanges().length;
        r.text.change('a${smile}b');

        expect(r.value, 'a${smile}b');
        expect(
          r.doc.exportChanges().length,
          afterFirst,
          reason: 'a no-op change() emitted operations',
        );
        expect(viaChanges(r.doc, factory), 'a${smile}b');
      });

      test('chained change() calls each land correctly', () {
        final steps = <String>[
          'a${grin}b',
          'a${smile}b',
          '$mathA${smile}b',
          '$familyGirl$mathA',
          flagDe,
          '',
          grin,
        ];

        final r = replicaWith(steps.first, factory);
        for (final step in steps.skip(1)) {
          r.text.change(step);
          expect(
            r.value,
            step,
            reason: 'local value wrong after change("$step") ${hex(r.value)}',
          );
        }

        expect(
          viaChanges(r.doc, factory),
          steps.last,
          reason: 'replaying the whole op history diverged from local state',
        );
        expect(viaSnapshot(r.doc, factory), steps.last);
      });
    });
  });
}

String _detail(ChangeCase c, String path, String actual) {
  final fffdBefore = c.to.codeUnits.where((u) => u == 0xFFFD).length;
  final fffdAfter = actual.codeUnits.where((u) => u == 0xFFFD).length;
  return '''
$path does not match the requested text.
  case          : ${c.name}
  probing       : ${c.why}
  from          : "${c.from}" ${hex(c.from)}
  to (expected) : "${c.to}" ${hex(c.to)}
  actual        : "$actual" ${hex(actual)}
  graphemes     : expected ${c.to.characters.length}, actual ${actual.characters.length}
  U+FFFD count  : expected $fffdBefore, actual $fffdAfter${fffdAfter > fffdBefore ? '  <-- replacement-char corruption' : ''}
  lone surrogates at: ${loneSurrogates(actual)}
  orphan ZWJ at     : ${orphanZwj(actual)}''';
}
