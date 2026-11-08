/// Tier 0 — regression guard for the historical non-BMP corruption bug.
///
/// Up to crdt_lf 3.3.0, element text was serialized with `utf8.encode`. A
/// non-BMP character is stored as two elements each holding a *lone surrogate*,
/// and `utf8.encode` of a lone surrogate is invalid UTF-8, so Dart substituted
/// U+FFFD. Every emoji became `��` the moment ops were serialized —
/// on sync and on snapshot alike. 3.4.2 replaced those call sites with WTF-8.
///
/// These tests pin that fix. They must fail loudly if anyone reverts a
/// `Wtf8.encode`/`Wtf8.decode` call site back to `utf8`.
library;

import 'package:test/test.dart';

import 'support/unicode_corpus.dart';
import 'support/unicode_support.dart';

void main() {
  handlers.forEach((handlerName, factory) {
    group(handlerName, () {
      test('local read is NOT sufficient evidence (documents the trap)', () {
        // The originating replica keeps the original half-strings in memory and
        // reconcatenates them, so it reads back correctly even when the wire
        // format is lossy. This is exactly what hid the bug from happy-path
        // tests, so every other assertion in this suite goes through a replica
        // rebuilt from bytes.
        final r = replicaWith('a${grin}b', factory);
        expect(r.value, 'a${grin}b');
      });

      test('non-BMP insert survives cross-replica sync', () {
        final r = replicaWith(grin, factory);
        final replicated = viaChanges(r.doc, factory);

        expect(
          replicated,
          grin,
          reason: 'emoji corrupted on the wire\n'
              '  want: ${hex(grin)}\n'
              '  got : ${hex(replicated)}\n'
              'Two U+FFFD (fffd, fffd) means a utf8.encode call site came back.',
        );
      });

      test('non-BMP insert survives snapshot/restore', () {
        final r = replicaWith(grin, factory);
        final restored = viaSnapshot(r.doc, factory);

        expect(
          restored,
          grin,
          reason: 'emoji corrupted through the persistence path\n'
              '  want: ${hex(grin)}\n'
              '  got : ${hex(restored)}',
        );
      });

      test('change() that splits a surrogate pair survives sync', () {
        // The original reported case: 'a😀b' -> 'a😃b' differs only in the LOW
        // surrogate, so change() emits delete(2,1) + insert(2, "\uDE03") — a
        // lone-surrogate payload on the wire.
        final r = replicaWith('a${grin}b', factory);
        r.text.change('a${smile}b');

        final replicated = viaChanges(r.doc, factory);
        expect(replicated, 'a${smile}b', reason: 'got ${hex(replicated)}');
        expect(viaSnapshot(r.doc, factory), 'a${smile}b');
      });

      test('astral CJK and math alphanumerics survive sync', () {
        for (final s in <String>[astralCjk, mathA, '$astralCjk X $mathA']) {
          final r = replicaWith(s, factory);
          expect(viaChanges(r.doc, factory), s, reason: 'failed for ${hex(s)}');
        }
      });

      test('no U+FFFD is introduced where the input had none', () {
        // The specific corruption signature, asserted directly. Note that a
        // "no lone surrogate" check does NOT catch this: U+FFFD is a perfectly
        // well-formed BMP character.
        final r = replicaWith('$grin$astralCjk$mathA', factory);
        final replicated = viaChanges(r.doc, factory);

        expect(
          replicated.codeUnits.where((u) => u == 0xFFFD),
          isEmpty,
          reason: 'replacement characters appeared: ${hex(replicated)}',
        );
      });
    });
  });
}
