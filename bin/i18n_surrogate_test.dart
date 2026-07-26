// =============================================================================
//  i18n/l10n ADVERSARIAL TEST: non-BMP (surrogate-pair) handling in crdt_lf
// =============================================================================
//
//  GRANULARITY FINDING (verified against source, not assumed)
//  ----------------------------------------------------------
//  A crdt_lf Fugue sequence element is keyed on ONE UTF-16 CODE UNIT.
//  Evidence -- crdt_lf 3.2.1, lib/src/handler/fugue_text/handler.dart:
//     insert(): line 53  `for (var i = 0; i < text.length; i++)`  // text.length = UTF-16 units
//               line 57  `text: text[i]`                          // text[i]    = one UTF-16 unit
//     update(): line 81/98  identical `text.length` / `text[i]` iteration
//  `String.length` and `text[i]` in Dart are UTF-16 code units (NOT runes,
//  NOT grapheme clusters). So a non-BMP character (a surrogate pair) is stored
//  as TWO elements, each holding one LONE surrogate.
//
//  diff_match_patch's diff() also operates on UTF-16 code units, so the diff
//  and the element cursor share granularity -- the walk is 1:1 consistent.
//
//  THE DEFECT THIS TEST SURFACES
//  -----------------------------
//  Each element's text is serialized with utf8.encode(text[i]) in
//  lib/src/handler/fugue_text/operation.dart. utf8.encode of a LONE surrogate
//  is not valid UTF-8, and Dart replaces it with U+FFFD (bytes EF BF BD).
//  Therefore any non-BMP character is corrupted to U+FFFD U+FFFD the moment its
//  ops cross a replica boundary (export -> import). The originating replica
//  reads correctly (its in-memory tree keeps the original half-strings), so the
//  happy-path/local test PASSES and hides the bug. Only a materialized remote
//  replica reveals the garbage -- and it converges to garbage deterministically.
//
//  This file walks diff_match_patch diffs into crdt_lf ops with BrainFrame's
//  cursor logic, replicates under both merge orderings + one duplicated
//  delivery, and asserts specific expected content + valid UTF-16. It is
//  EXPECTED TO FAIL. Do not "fix" the test to make it pass; the gap is the
//  result.
// =============================================================================

import 'package:crdt_lf/crdt_lf.dart';
import 'package:diff_match_patch/diff_match_patch.dart';

final peerA = PeerId.parse('aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa');
final peerB = PeerId.parse('bbbbbbbb-bbbb-4bbb-bbbb-bbbbbbbbbbbb');

int _failures = 0;
int _checks = 0;

void main() {
  // Non-BMP characters used below:
  //   😀 U+1F600 = D83D DE00   😃 U+1F603 = D83D DE03  (differ only in low unit)
  //   𠀀 U+20000 = D840 DC00   (astral-plane CJK Extension B)
  //   𝐀 U+1D400 = D835 DC00   (MATHEMATICAL BOLD CAPITAL A)

  // 1) Baseline: a plain emoji insert (no split) -- proves corruption needs no diff.
  scenario('baseline-insert-emoji', 'hello world', 'hello 😀 world');

  // 2) Minimal diff boundary lands INSIDE a surrogate pair (low unit edited).
  scenario('split-inside-pair', 'a😀b', 'a😃b');

  // 3) Edit flanked by astral characters; boundary sits immediately adjacent.
  scenario('flanked-by-astral', '𠀀X𝐀', '𠀀Y𝐀');

  // 4) Insert between two emoji: boundary between one pair's low unit and the
  //    next pair's high unit.
  scenario('insert-between-emoji', '😀😀', '😀Z😀');

  // Show the malformed op on the wire for scenario 2.
  reportMalformedOps('split-inside-pair', 'a😀b', 'a😃b');

  print('\n============================================================');
  print('SUMMARY: $_checks checks, $_failures FAILED');
  if (_failures > 0) {
    print('RESULT: crdt_lf corrupts non-BMP text across replicas.');
    print('        The element granularity is UTF-16 code units, and lone');
    print('        surrogates are replaced by U+FFFD during utf8 serialization.');
    print('        STOPPING per instructions -- not adjusting the test to pass.');
  } else {
    print('RESULT: no corruption observed (unexpected -- re-examine).');
  }
}

// --- BrainFrame cursor walk: DIFF_EQUAL advances, DIFF_DELETE tombstones,
//     DIFF_INSERT creates between neighbors. Positions are UTF-16 code units,
//     which equal element positions in crdt_lf (both code-unit granularity). ---
void applyDiff(CRDTFugueTextHandler h, List<Diff> diffs) {
  var cursor = 0;
  for (final d in diffs) {
    switch (d.operation) {
      case DIFF_EQUAL:
        cursor += d.text.length;
      case DIFF_DELETE:
        h.delete(cursor, d.text.length); // tombstone; cursor stays put
      case DIFF_INSERT:
        h.insert(cursor, d.text); // create between the current neighbors
        cursor += d.text.length;
    }
  }
}

void scenario(String name, String oldText, String newText) {
  print('\n=== $name ===');
  print('  old="$oldText"  units=${hexUnits(oldText)}');
  print('  new="$newText"  units=${hexUnits(newText)}');

  // Replica A: seed with old text, then diff-walk to new text.
  final a = CRDTDocument(peerId: peerA);
  final ta = CRDTFugueTextHandler(a, 't');
  ta.insert(0, oldText);

  final diffs = diff(oldText, newText); // raw, minimal, code-unit boundaries
  print('  diff = ${diffs.join(' ')}');
  applyDiff(ta, diffs);
  print('  A(local)="${ta.value}"  units=${hexUnits(ta.value)}  '
      'validUtf16=${isValidUtf16(ta.value)}');

  // Replicate to B under: in-order, reversed, and one duplicated delivery.
  // Each delivery is a SEQUENCE of import batches (a duplicated delivery is a
  // re-sent message = a separate, idempotent import call -- not a duplicate
  // within one batch, which would be an ill-formed input).
  final changes = a.exportChanges();
  final deliveries = <String, List<List<Change>>>{
    'in-order': [changes],
    'reversed': [changes.reversed.toList()],
    'dup-last': [changes, [changes.last]],
  };

  for (final entry in deliveries.entries) {
    final b = CRDTDocument(peerId: peerB, documentId: a.documentId);
    final tb = CRDTFugueTextHandler(b, 't');
    for (final batch in entry.value) {
      b.importChanges(batch);
    }
    final got = tb.value;
    print('  B[${entry.key}]="$got"  units=${hexUnits(got)}');
    // Assert on SPECIFIC expected content, not just replica agreement.
    check('$name/${entry.key}: B == expected new text', got == newText,
        newText, got);
    check('$name/${entry.key}: B byte-equal to A(local)', got == ta.value,
        ta.value, got);
    check('$name/${entry.key}: B is valid UTF-16 (no lone surrogate)',
        isValidUtf16(got), '<valid utf16>', got);
  }
}

// Dump the wire bytes of the ops and flag the U+FFFD (EF BF BD) replacements
// that stand where a surrogate code unit should be.
void reportMalformedOps(String name, String oldText, String newText) {
  print('\n--- malformed-op evidence ($name) ---');
  final a = CRDTDocument(peerId: peerA);
  final ta = CRDTFugueTextHandler(a, 't');
  ta.insert(0, oldText);
  applyDiff(ta, diff(oldText, newText));

  for (final ch in a.exportChanges()) {
    final bytes = ch.payloadBytes();
    final hits = <int>[];
    for (var i = 0; i + 2 < bytes.length; i++) {
      if (bytes[i] == 0xEF && bytes[i + 1] == 0xBF && bytes[i + 2] == 0xBD) {
        hits.add(i);
      }
    }
    if (hits.isNotEmpty) {
      print('  change ${ch.author}@${ch.hlc}:');
      print('    payload = ${bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}');
      print('    U+FFFD (ef bf bd) at byte offsets $hits  '
          '<- a surrogate code unit was destroyed here');
    }
  }
}

// --- assertion + formatting helpers ---
void check(String label, bool ok, String expected, String actual) {
  _checks++;
  if (ok) {
    print('    PASS  $label');
  } else {
    _failures++;
    print('    FAIL  $label');
    print('          expected units=${hexUnits(expected)}');
    print('          actual   units=${hexUnits(actual)}');
  }
}

List<String> hexUnits(String s) =>
    s.codeUnits.map((c) => c.toRadixString(16).padLeft(4, '0')).toList();

bool isValidUtf16(String s) {
  final u = s.codeUnits;
  for (var i = 0; i < u.length; i++) {
    final c = u[i];
    if (c >= 0xD800 && c <= 0xDBFF) {
      // high surrogate must be followed by a low surrogate
      if (i + 1 >= u.length || u[i + 1] < 0xDC00 || u[i + 1] > 0xDFFF) {
        return false;
      }
      i++; // consume the low surrogate
    } else if (c >= 0xDC00 && c <= 0xDFFF) {
      return false; // lone low surrogate
    }
  }
  return true;
}
