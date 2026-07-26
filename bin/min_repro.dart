import 'package:crdt_lf/crdt_lf.dart';

// Minimal repro: crdt_lf corrupts non-BMP (surrogate-pair) text to U+FFFD when
// an element/op value is serialized as a LONE surrogate. Verified on 3.4.0+2.
//
// The point of this file: the SINGLE-instance, in-memory case is CORRECT for
// both text handlers. The bug appears whenever state is rebuilt from serialized
// bytes -- a second replica (sync) OR the same doc reloaded from a snapshot
// (persistence). It is a serialization defect, not a CRDT-logic defect.
void main() {
  List<int> u(String s) => s.codeUnits;

  // --- CRDTFugueTextHandler: any non-BMP insert. ---
  {
    final a = CRDTDocument();
    final ta = CRDTFugueTextHandler(a, 't');
    ta.insert(0, '😀'); // U+1F600
    // Single instance -> CORRECT.
    print('Fugue single doc          : "${ta.value}" ${u(ta.value)}');
    // Second replica (same documentId), built from serialized changes -> BROKEN.
    final b = CRDTDocument(documentId: a.documentId);
    final tb = CRDTFugueTextHandler(b, 't');
    b.importChanges(a.exportChanges());
    print('Fugue second replica      : "${tb.value}" ${u(tb.value)}');
    print('  want "😀" ${u('😀')}\n');
  }

  // --- CRDTTextHandler: an edit that splits a surrogate pair (via change()). ---
  {
    final a = CRDTDocument();
    final ha = CRDTTextHandler(a, 't');
    ha.insert(0, 'a😀b');
    // change()'s Myers diff works per code unit: it deletes 1 unit at index 2
    // (the low surrogate DE00) and inserts 1 unit at index 2 (the new low
    // surrogate DE03). That lone-surrogate insert is what utf8.encode turns into
    // U+FFFD. (Verified by decoding the ops: delete idx2 count1; insert idx2
    // [ef bf bd].) The high surrogate at index 1 is left untouched.
    ha.change('a😃b');
    // Single instance -> CORRECT.
    print('Text single doc           : "${ha.value}" ${u(ha.value)}');
    // Second replica (same documentId), built from serialized changes -> BROKEN.
    final b = CRDTDocument(documentId: a.documentId);
    final tb = CRDTTextHandler(b, 't');
    b.importChanges(a.exportChanges());
    print('Text second replica       : "${tb.value}" ${u(tb.value)}');
    print('  want "a😃b" ${u('a😃b')}\n');
  }

  // --- Persistence: ONE doc, no second replica. Snapshot -> bytes -> reload. ---
  // Same peer, same documentId, rebuilt only from the snapshot bytes (i.e. a
  // restart / load-from-disk). The snapshot encodes element values with
  // utf8.encode too, so a single peer loses the emoji on reload.
  {
    final a = CRDTDocument();
    final ta = CRDTFugueTextHandler(a, 't');
    ta.insert(0, '😀');
    // Single instance, before persisting -> CORRECT.
    print('Snapshot before save      : "${ta.value}" ${u(ta.value)}');
    final snapBytes = a.takeSnapshot(pruneHistory: false).toBytes();

    final a2 = CRDTDocument(peerId: a.peerId, documentId: a.documentId);
    final ta2 = CRDTFugueTextHandler(a2, 't');
    a2.import(snapshot: Snapshot.fromBytes(snapBytes));
    print('Snapshot after reload     : "${ta2.value}" ${u(ta2.value)}');
    print('  want "😀" ${u('😀')}');
  }
}
