/// Snapshot determinism — crdt_lf 3.5.0.
///
/// Question: if two peers hold exactly the same set of edits, is
/// `takeSnapshot(pruneHistory: false).toBytes()` byte-identical on both?
///
/// Every case builds a scenario, then compares the snapshot of each peer
/// against the first one twice:
///   * `raw`       — the bytes `Snapshot.toBytes()` produces;
///   * `canonical` — the same snapshot re-encoded with the version vector,
///                   the handler entries and the element-id floor sorted by
///                   key (handler payload kept as is). See [canonical].
///
/// On a mismatch the failure message names the component that differs
/// (snapshot id, version vector, handler key order, handler node payload, or
/// element-id floor) and whether it is an ordering or a content difference.
/// A summary table of every comparison is printed at the end of the run.
///
/// Each peer is snapshotted at most once per comparison, on purpose: even a
/// `pruneHistory: false` snapshot is stored as the document's `_lastSnapshot`
/// and changes how the next one is built (see case 5b and case 6).
///
/// Run with: dart test test/snapshot_determinism_test.dart
library;

import 'dart:typed_data';

import 'package:crdt_lf/crdt_lf.dart';
import 'package:hlc_dart/hlc_dart.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Peers
// ---------------------------------------------------------------------------

/// Fixed peer IDs. Their sort order (B < C < A < D < E) deliberately differs
/// from the order the peers are created and write in, so "sorted by peer ID"
/// and "insertion order" never coincide by accident.
final _ids = <String, String>{
  'A': 'c0000000-0000-4000-8000-00000000000a',
  'B': 'a0000000-0000-4000-8000-00000000000b',
  'C': 'b0000000-0000-4000-8000-00000000000c',
  'D': 'd0000000-0000-4000-8000-00000000000d',
  'E': 'e0000000-0000-4000-8000-00000000000e',
};

const _documentId = 'determinism-doc';
const _handlerKey = 'note';

String _observerId(int n) =>
    'f0000000-0000-4000-8000-${n.toRadixString(16).padLeft(12, '0')}';

final _names = <String, String>{
  for (final e in _ids.entries) e.value: e.key,
};

String _name(String peerId) =>
    _names[peerId] ?? 'obs${int.parse(peerId.substring(24), radix: 16)}';

class Peer {
  Peer(this.name, String peerId)
      : doc = CRDTDocument(
          peerId: PeerId.parse(peerId),
          documentId: _documentId,
        ) {
    text = CRDTFugueTextHandler(doc, _handlerKey);
  }

  factory Peer.named(String name) => Peer(name, _ids[name]!);

  final String name;
  final CRDTDocument doc;
  late final CRDTFugueTextHandler text;

  /// Pulls everything [from] holds, using the binary change codec.
  void pull(Peer from) => doc.binaryImportChanges(from.doc.binaryExportChanges());

  Uint8List snap() => doc.takeSnapshot(pruneHistory: false).toBytes();
}

// ---------------------------------------------------------------------------
// Snapshot decomposition
// ---------------------------------------------------------------------------

class FloorEntry {
  FloorEntry(this.peer, this.counter);
  final String peer;
  final int counter;
  @override
  String toString() => '${_name(peer)}:$counter';
}

class VvEntry {
  VvEntry(this.peer, this.hlcBytes);
  final String peer;
  final Uint8List hlcBytes;
  @override
  String toString() {
    final h = HybridLogicalClock.fromUint8List(hlcBytes);
    return '${_name(peer)}@${h.l}.${h.c}';
  }
}

class HandlerPart {
  HandlerPart(this.nodesRaw, this.floor, this.liveNodes);

  /// Node list exactly as the handler wrote it (count + nodes), floor removed.
  final Uint8List nodesRaw;
  final List<FloorEntry> floor;
  final int liveNodes;
}

class Decoded {
  Decoded(this.id, this.vv, this.handlers);
  final String id;
  final List<VvEntry> vv;

  /// Insertion order of [handlers] is the on-the-wire order.
  final Map<String, HandlerPart> handlers;
}

Decoded decode(Uint8List bytes) {
  final s = Snapshot.fromBytes(bytes);

  final vvBytes = s.versionVector.toBytes(); // fromBytes keeps wire order
  var o = 0;
  final n = UVarint.read(vvBytes, offset: o);
  o = n.nextOffset;
  final vv = <VvEntry>[];
  for (var i = 0; i < n.value; i++) {
    final peer = PeerId.fromUint8List(vvBytes, offset: o).id;
    vv.add(VvEntry(peer, Uint8List.fromList(vvBytes.sublist(o + 16, o + 24))));
    o += 24;
  }

  final handlers = <String, HandlerPart>{};
  for (final e in s.data.entries) {
    handlers[e.key] = _decodeFuguePayload(e.value);
  }
  return Decoded(s.id, vv, handlers);
}

/// Splits a Fugue handler payload (fugue_sequence_handler.dart:206-222) into
/// its node list and the trailing ElementIdFloor (element_id_floor.dart:24).
HandlerPart _decodeFuguePayload(Uint8List p) {
  var o = 0;
  final count = UVarint.read(p, offset: o);
  o = count.nextOffset;
  for (var i = 0; i < count.value; i++) {
    final idLen = UVarint.read(p, offset: o);
    o = idLen.nextOffset + idLen.value;
    final valLen = UVarint.read(p, offset: o);
    o = valLen.nextOffset + valLen.value;
  }
  final nodesRaw = Uint8List.fromList(p.sublist(0, o));

  final floor = <FloorEntry>[];
  if (o < p.length) {
    final fc = UVarint.read(p, offset: o);
    o = fc.nextOffset;
    for (var i = 0; i < fc.value; i++) {
      final peer = PeerId.fromUint8List(p, offset: o).id;
      o += 16;
      final c = UVarint.read(p, offset: o);
      o = c.nextOffset;
      floor.add(FloorEntry(peer, c.value));
    }
  }
  if (o != p.length) {
    throw StateError('trailing bytes in handler payload');
  }
  return HandlerPart(nodesRaw, floor, count.value);
}

// ---------------------------------------------------------------------------
// Canonical form
// ---------------------------------------------------------------------------

/// Re-encodes [bytes] in the same layout as Snapshot.toBytes, but with
/// - version vector entries sorted by peer ID,
/// - handler entries sorted by key,
/// - each Fugue payload's element-id floor sorted by peer ID,
/// and the handler node list left exactly as written.
///
/// UUID strings are lowercase hex with fixed dash positions, so sorting by
/// `PeerId.id` equals sorting by the 16 raw bytes.
Uint8List canonical(Uint8List bytes) {
  final d = decode(bytes);
  final out = BytesBuilder(copy: false);

  void lenPrefixed(List<int> b) {
    UVarint.write(b.length, out);
    out.add(b);
  }

  lenPrefixed(Uint8List.fromList(d.id.codeUnits));

  final vv = [...d.vv]..sort((a, b) => a.peer.compareTo(b.peer));
  final vvOut = BytesBuilder(copy: false);
  UVarint.write(vv.length, vvOut);
  for (final e in vv) {
    vvOut
      ..add(PeerId.parse(e.peer).toUint8List())
      ..add(e.hlcBytes);
  }
  lenPrefixed(vvOut.toBytes());

  final keys = d.handlers.keys.toList()..sort();
  UVarint.write(keys.length, out);
  for (final k in keys) {
    lenPrefixed(Uint8List.fromList(k.codeUnits));
    final h = d.handlers[k]!;
    final payload = BytesBuilder(copy: false)..add(h.nodesRaw);
    final floor = [...h.floor]..sort((a, b) => a.peer.compareTo(b.peer));
    UVarint.write(floor.length, payload);
    for (final f in floor) {
      payload.add(PeerId.parse(f.peer).toUint8List());
      UVarint.write(f.counter, payload);
    }
    lenPrefixed(payload.toBytes());
  }
  return out.toBytes();
}

// ---------------------------------------------------------------------------
// Comparison + diagnosis
// ---------------------------------------------------------------------------

bool _bytesEq(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

String _orderOrContent<T>(
  List<T> a,
  List<T> b,
  String Function(T) key,
) {
  final sa = a.map((e) => e.toString()).toList();
  final sb = b.map((e) => e.toString()).toList();
  if (sa.join() == sb.join()) return '';
  final ka = (a.map(key).toList()..sort()).join();
  final kb = (b.map(key).toList()..sort()).join();
  final setA = (sa.toList()..sort()).join(',');
  final setB = (sb.toList()..sort()).join(',');
  if (setA == setB) return 'ORDER ONLY $sa vs $sb';
  if (ka == kb) return 'VALUES differ $sa vs $sb';
  return 'CONTENT differs $sa vs $sb';
}

/// Human-readable list of the components that differ between two snapshots.
List<String> diagnose(Uint8List a, Uint8List b) {
  final da = decode(a);
  final db = decode(b);
  final out = <String>[];
  if (da.id != db.id) out.add('snapshot id differs');
  final vv = _orderOrContent(da.vv, db.vv, (e) => e.peer);
  if (vv.isNotEmpty) out.add('versionVector: $vv');
  final ka = da.handlers.keys.join(',');
  final kb = db.handlers.keys.join(',');
  if (ka != kb) out.add('handler keys: [$ka] vs [$kb]');
  for (final k in da.handlers.keys) {
    final ha = da.handlers[k]!;
    final hb = db.handlers[k];
    if (hb == null) continue;
    if (!_bytesEq(ha.nodesRaw, hb.nodesRaw)) {
      out.add('handler "$k" node payload differs '
          '(${ha.liveNodes} vs ${hb.liveNodes} nodes)');
    }
    final f = _orderOrContent(ha.floor, hb.floor, (e) => e.peer);
    if (f.isNotEmpty) out.add('handler "$k" floor: $f');
  }
  if (out.isEmpty && !_bytesEq(a, b)) out.add('bytes differ (unclassified)');
  return out;
}

class Result {
  Result(this.caseName, this.label, this.raw, this.canon, this.why);
  final String caseName;
  final String label;
  final bool raw;
  final bool canon;
  final List<String> why;
}

final _results = <Result>[];

/// Registers raw + canonical comparison tests of every snapshot in [snaps]
/// against the first one. [build] runs once, lazily, in setUpAll.
void compareGroup(
  String caseName,
  Map<String, Uint8List> Function() build, {
  void Function(Map<String, Uint8List> snaps)? extra,
}) {
  group(caseName, () {
    late Map<String, Uint8List> snaps;
    setUpAll(() {
      snaps = build();
      final refLabel = snaps.keys.first;
      final ref = snaps[refLabel]!;
      for (final e in snaps.entries.skip(1)) {
        final raw = _bytesEq(ref, e.value);
        final canon = _bytesEq(canonical(ref), canonical(e.value));
        _results.add(Result(
          caseName,
          '$refLabel vs ${e.key}',
          raw,
          canon,
          raw ? const [] : diagnose(ref, e.value),
        ));
      }
    });

    test('raw toBytes() identical on every peer', () {
      final bad = _results
          .where((r) => r.caseName == caseName && !r.raw)
          .map((r) => '${r.label}:\n    ${r.why.join('\n    ')}')
          .toList();
      expect(bad.length, 0,
          reason: '${bad.length} snapshot(s) differ from the first:\n'
              '${bad.take(3).join('\n')}${bad.length > 3 ? '\n  ...' : ''}');
    });

    test('canonical form identical on every peer', () {
      final bad = <String>[];
      final ref = canonical(snaps.values.first);
      for (final e in snaps.entries.skip(1)) {
        final c = canonical(e.value);
        if (!_bytesEq(ref, c)) {
          bad.add('${snaps.keys.first} vs ${e.key}: '
              '${diagnose(snaps.values.first, e.value).join('; ')}');
        }
      }
      expect(bad.length, 0, reason: bad.join('\n'));
    });

    if (extra != null) {
      test('case-specific checks', () => extra(snaps));
    }
  });
}

Iterable<List<T>> permutations<T>(List<T> xs) sync* {
  if (xs.length <= 1) {
    yield [...xs];
    return;
  }
  for (var i = 0; i < xs.length; i++) {
    final rest = [...xs]..removeAt(i);
    for (final p in permutations(rest)) {
      yield [xs[i], ...p];
    }
  }
}

void _expectSameText(Iterable<Peer> peers) {
  final values = {for (final p in peers) p.name: p.text.value};
  expect(values.values.toSet().length, 1, reason: 'peers diverged: $values');
}

// ---------------------------------------------------------------------------
// Cases
// ---------------------------------------------------------------------------

void main() {
  // 1. Same edits, different arrival order.
  compareGroup('case 1: two writers, two arrival orders', () {
    final a = Peer.named('A');
    final b = Peer.named('B');
    final c = Peer.named('C');
    final d = Peer.named('D');
    a.text
      ..insert(0, 'alpha ')
      ..insert(6, 'one');
    b.text
      ..insert(0, 'bravo ')
      ..insert(6, 'two');
    c
      ..pull(a)
      ..pull(b);
    d
      ..pull(b)
      ..pull(a);
    a.pull(b);
    b.pull(a);
    _expectSameText([a, b, c, d]);
    return {
      'A': a.snap(),
      'B': b.snap(),
      'C(A→B)': c.snap(),
      'D(B→A)': d.snap(),
    };
  });

  // 2. Three or more writers, every delivery order.
  for (final writerNames in [
    ['A', 'B', 'C'],
    ['A', 'B', 'C', 'D'],
  ]) {
    compareGroup(
        'case 2: ${writerNames.length} writers, all '
        '${permutations(writerNames).length} delivery orders', () {
      final writers = [for (final n in writerNames) Peer.named(n)];
      for (final (i, w) in writers.indexed) {
        w.text.insert(0, '${w.name.toLowerCase() * 3}$i ');
        w.text.insert(w.text.length, '<${w.name}>');
      }
      final snaps = <String, Uint8List>{};
      var obs = 1;
      final observers = <Peer>[];
      for (final order in permutations(writers)) {
        final o = Peer('obs$obs', _observerId(obs));
        obs++;
        for (final w in order) {
          o.pull(w);
        }
        observers.add(o);
        snaps['obs(${order.map((w) => w.name).join('→')})'] = o.snap();
      }
      // Writers converge too (each pulls the others in fixed order).
      for (final w in writers) {
        for (final other in writers) {
          if (other != w) w.pull(other);
        }
      }
      _expectSameText([...writers, ...observers]);
      for (final w in writers) {
        snaps['writer ${w.name}'] = w.snap();
      }
      return snaps;
    });
  }

  // 3. Deletions.
  compareGroup(
    'case 3: deletion on another peer',
    () {
      final a = Peer.named('A');
      final b = Peer.named('B');
      final c = Peer.named('C');
      a.text.insert(0, 'keep this, drop that'); // A counters 0..19
      b.pull(a);
      b.text.delete(10, 10); // deletes ' drop that' -> A's counters 10..19
      b.text.insert(b.text.length, '!'); // B counter 0
      a.pull(b);
      // C sees B's export first (it already contains A's insert).
      c
        ..pull(b)
        ..pull(a);
      _expectSameText([a, b, c]);
      expect(a.text.value, 'keep this,!');
      return {'A': a.snap(), 'B': b.snap(), 'C': c.snap()};
    },
    extra: (snaps) {
      final h = decode(snaps['A']!).handlers[_handlerKey]!;
      // Tombstones are NOT written: only the 11 live characters are.
      expect(h.liveNodes, 'keep this,!'.length);
      // ...but the floor still remembers A's deleted counters (max 19).
      final floorA =
          h.floor.firstWhere((f) => f.peer == _ids['A']).counter;
      expect(floorA, 19,
          reason: 'floor should carry the counter of deleted elements');
    },
  );

  // 4. Concurrent inserts at the same position.
  compareGroup('case 4: concurrent inserts at the same position', () {
    final a = Peer.named('A');
    final b = Peer.named('B');
    final c = Peer.named('C');
    final d = Peer.named('D');
    // Seed from a third peer so A's and B's first changes are concurrent and
    // the arrival order really varies between C and D.
    final e = Peer.named('E');
    e.text.insert(0, '[]');
    for (final p in [a, b, c, d]) {
      p.pull(e);
    }
    a.text.insert(1, 'from A');
    b.text.insert(1, 'from B');
    c
      ..pull(a)
      ..pull(b);
    d
      ..pull(b)
      ..pull(a);
    a.pull(b);
    b.pull(a);
    _expectSameText([a, b, c, d]);
    return {
      'A': a.snap(),
      'B': b.snap(),
      'C(A→B)': c.snap(),
      'D(B→A)': d.snap(),
    };
  });

  // 5. Earlier compaction on one peer.
  //
  // B writes text that A then deletes, and B never writes again, so after A
  // compacts the only trace of B's counters on A is the carried-over floor.
  Map<String, Uint8List> earlierSnapshot({required bool prune}) {
    final a = Peer.named('A');
    final b = Peer.named('B');
    final c = Peer.named('C');
    final d = Peer.named('D'); // never snapshots until the end
    a.text.insert(0, 'hello world');
    b.pull(a);
    b.text.insert(b.text.length, ' from B');
    a.pull(b);
    a.text.delete(11, 7); // removes all of B's text
    for (final p in [b, c, d]) {
      p.pull(a);
    }

    a.doc.takeSnapshot(pruneHistory: prune); // <-- the earlier snapshot

    a.text.insert(a.text.length, '!');
    c.text.insert(0, '> ');
    // Full sync. A cannot re-export pruned changes, but every peer already
    // holds them from the round above.
    for (final to in [a, b, c, d]) {
      for (final from in [a, b, c, d]) {
        if (from != to) to.pull(from);
      }
    }
    _expectSameText([a, b, c, d]);
    expect(a.text.value, '> hello world!');
    return {'D (never snapshotted)': d.snap(), 'A (earlier snapshot)': a.snap(),
        'B': b.snap(), 'C': c.snap()};
  }

  compareGroup('case 5: A compacted earlier (pruneHistory: true)',
      () => earlierSnapshot(prune: true));
  compareGroup('case 5b: A snapshotted earlier without pruning',
      () => earlierSnapshot(prune: false));

  // 6. Restart from a snapshot.
  compareGroup('case 6: restart via importSnapshot', () {
    final a = Peer.named('A');
    final b = Peer.named('B');
    final c = Peer.named('C');
    // B writes first so B's id appears in the tree after A's text but before
    // it in HLC order: tree order and replay order disagree on peer order.
    b.text.insert(0, 'tail');
    a.pull(b);
    a.text.insert(0, 'head ');
    c.pull(a);
    c.text.insert(5, 'mid ');
    a.pull(c);
    b.pull(a);
    c.pull(b);
    _expectSameText([a, b, c]);

    final original = a.snap();
    final again = a.snap(); // same doc, second snapshot, no new edits

    Uint8List restart(String peerId) {
      final r = Peer('R', peerId);
      final applied = r.doc.importSnapshot(Snapshot.fromBytes(original));
      expect(applied, isTrue);
      expect(r.text.value, a.text.value);
      return r.snap();
    }

    return {
      'A original': original,
      'A second takeSnapshot': again,
      'restart as A': restart(_ids['A']!),
      'restart as new peer E': restart(_ids['E']!),
    };
  });

  // 7. (extra) Importing an older snapshot while already holding newer
  // changes. DAG.prune -> _removeNodes (dag/graph.dart:133) drops the whole
  // version-vector entry of every peer that had *any* node pruned, even if
  // newer nodes of that peer survive; getVersionVector (document.dart:672)
  // then falls back to the snapshot's older clock for that peer.
  compareGroup(
    'case 7: importSnapshot of an older snapshot over newer changes',
    () {
      final a = Peer.named('A');
      final b = Peer.named('B');
      final c = Peer.named('C');
      final d = Peer.named('D');
      a.text.insert(0, 'one');
      c.pull(a);
      final older = c.doc.takeSnapshot(pruneHistory: false);
      a.text.insert(3, ' two');
      b.pull(a);
      d.pull(a);
      expect(b.doc.importSnapshot(older), isTrue);
      _expectSameText([a, b, d]);
      expect(b.text.value, 'one two');
      return {'D (no snapshot)': d.snap(), 'B (imported older)': b.snap()};
    },
  );

  tearDownAll(() {
    final buf = StringBuffer()
      ..writeln()
      ..writeln('=== snapshot determinism summary (crdt_lf 3.5.0) ===')
      ..writeln('peer order by ID: B < C < A < D < E');
    String? last;
    for (final r in _results) {
      if (r.caseName != last) {
        buf.writeln('\n${r.caseName}');
        last = r.caseName;
      }
      buf.writeln('  ${r.raw ? 'RAW OK ' : 'RAW DIFF'} | '
          '${r.canon ? 'CANON OK ' : 'CANON DIFF'} | ${r.label}');
      for (final w in r.why) {
        buf.writeln('      - $w');
      }
    }
    // ignore: avoid_print
    print(buf);
  });
}
