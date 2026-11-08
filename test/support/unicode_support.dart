/// Shared harness for the `change()` Unicode test suite.
///
/// Two things matter here and are easy to get wrong:
///
/// 1. **Always assert on a replica built FROM SERIALIZED BYTES.** The
///    originating document keeps the original (possibly half-pair) strings in
///    memory and reconcatenates them, so a local read hides any wire-format
///    defect. Every assertion goes through [viaChanges] or [viaSnapshot].
/// 2. **`U+FFFD` is valid UTF-16.** A "no lone surrogate" check does not catch
///    replacement-character corruption. Tier 1/3 assert exact expected content;
///    the well-formedness helpers here are for tier 2, where concurrent edits
///    mean there is no single correct answer and well-formedness is the only
///    invariant left to check.
library;

import 'package:characters/characters.dart';
import 'package:crdt_lf/crdt_lf.dart';

/// Uniform surface over the two text handlers, so tiers 1/3/4 can run the
/// identical body against both.
abstract class TextFacade {
  String get value;

  void insert(int index, String text);

  void delete(int index, int count);

  void change(String newText);
}

class _FugueFacade implements TextFacade {
  _FugueFacade(this._h);

  final CRDTFugueTextHandler _h;

  @override
  String get value => _h.value;

  @override
  void insert(int index, String text) => _h.insert(index, text);

  @override
  void delete(int index, int count) => _h.delete(index, count);

  @override
  void change(String newText) => _h.change(newText);
}

class _PlainFacade implements TextFacade {
  _PlainFacade(this._h);

  final CRDTTextHandler _h;

  @override
  String get value => _h.value;

  @override
  void insert(int index, String text) => _h.insert(index, text);

  @override
  void delete(int index, int count) => _h.delete(index, count);

  @override
  void change(String newText) => _h.change(newText);
}

/// Attaches a text handler named [id] to [doc].
typedef HandlerFactory = TextFacade Function(CRDTDocument doc, String id);

/// The two handlers under test. Both expose an identical `change()`; they
/// differ in storage model (one Fugue element per UTF-16 code unit vs.
/// index-addressed runs of code units), so both need covering.
const Map<String, HandlerFactory> handlers = <String, HandlerFactory>{
  'CRDTFugueTextHandler': _fugue,
  'CRDTTextHandler': _plain,
};

TextFacade _fugue(CRDTDocument doc, String id) =>
    _FugueFacade(CRDTFugueTextHandler(doc, id));

TextFacade _plain(CRDTDocument doc, String id) =>
    _PlainFacade(CRDTTextHandler(doc, id));

/// Handler id used throughout the suite.
const String kHandlerId = 't';

/// Recognisable valid v4 peer ids (version nibble `4`, variant nibble in
/// {8,9,a,b} — `PeerId.parse` rejects anything else).
const String kPeerA = 'aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa';
const String kPeerB = 'bbbbbbbb-bbbb-4bbb-bbbb-bbbbbbbbbbbb';

/// A document plus its attached handler.
class Replica {
  Replica(this.doc, this.text);

  final CRDTDocument doc;
  final TextFacade text;

  String get value => text.value;
}

/// Creates a fresh replica. Pass [peerId]/[documentId] when identity matters
/// (concurrency tests); omit for single-replica tests.
Replica newReplica(
  HandlerFactory factory, {
  String? peerId,
  Object? documentId,
}) {
  final doc = CRDTDocument(
    peerId: peerId == null ? null : PeerId.parse(peerId),
    documentId: documentId as dynamic,
  );
  return Replica(doc, factory(doc, kHandlerId));
}

/// Builds a replica whose text is [initial], inserted as one operation.
Replica replicaWith(
  String initial,
  HandlerFactory factory, {
  String? peerId,
}) {
  final r = newReplica(factory, peerId: peerId);
  if (initial.isNotEmpty) {
    r.text.insert(0, initial);
  }
  return r;
}

/// Exports [source]'s changes, imports them into a brand-new replica, and
/// returns that replica's value. This is the assertion path that actually
/// exercises serialization.
String viaChanges(CRDTDocument source, HandlerFactory factory) {
  final b = CRDTDocument(documentId: source.documentId);
  final hb = factory(b, kHandlerId);
  b.importChanges(source.exportChanges());
  return hb.value;
}

/// Snapshots [source] to bytes and rebuilds a replica from those bytes alone
/// (i.e. the persistence / restart path), returning its value.
String viaSnapshot(CRDTDocument source, HandlerFactory factory) {
  final bytes = source.takeSnapshot(pruneHistory: false).toBytes();
  final b = CRDTDocument(peerId: source.peerId, documentId: source.documentId);
  final hb = factory(b, kHandlerId);
  b.import(snapshot: Snapshot.fromBytes(bytes));
  return hb.value;
}

/// Outcome of merging two concurrent edits in both directions.
class MergeOutcome {
  MergeOutcome({
    required this.base,
    required this.aBeforeMerge,
    required this.bBeforeMerge,
    required this.aAfterMerge,
    required this.bAfterMerge,
    required this.bAfterDuplicate,
  });

  /// Text both replicas started from.
  final String base;

  /// Replica A's local value after its own edit, before hearing from B.
  final String aBeforeMerge;

  /// Replica B's local value after its own edit, before hearing from A.
  final String bBeforeMerge;

  /// The three texts a merge is allowed to draw characters from.
  List<String> get inputs => <String>[base, aBeforeMerge, bBeforeMerge];

  /// Replica A's value after importing B's changes.
  final String aAfterMerge;

  /// Replica B's value after importing A's changes.
  final String bAfterMerge;

  /// Replica B after A's changes were delivered a second time (idempotence).
  final String bAfterDuplicate;

  bool get converged =>
      aAfterMerge == bAfterMerge && bAfterMerge == bAfterDuplicate;
}

/// Applies [editA] on replica A and [editB] concurrently on replica B, both
/// starting from [base], then syncs both directions and re-delivers A's
/// changes once more.
///
/// Duplicated delivery must be a *separate* `importChanges` call — a repeated
/// entry inside one batch trips the topological sort's cycle check.
MergeOutcome mergeConcurrent({
  required String base,
  required void Function(TextFacade) editA,
  required void Function(TextFacade) editB,
  required HandlerFactory factory,
}) {
  final a = replicaWith(base, factory, peerId: kPeerA);

  final bDoc = CRDTDocument(
    peerId: PeerId.parse(kPeerB),
    documentId: a.doc.documentId,
  );
  final bText = factory(bDoc, kHandlerId);
  bDoc.importChanges(a.doc.exportChanges());

  editA(a.text);
  editB(bText);

  final aLocal = a.text.value;
  final bLocal = bText.value;

  final changesA = a.doc.exportChanges();
  final changesB = bDoc.exportChanges();

  bDoc.importChanges(changesA);
  a.doc.importChanges(changesB);

  final aMerged = a.text.value;
  final bMerged = bText.value;

  bDoc.importChanges(changesA);

  return MergeOutcome(
    base: base,
    aBeforeMerge: aLocal,
    bBeforeMerge: bLocal,
    aAfterMerge: aMerged,
    bAfterMerge: bMerged,
    bAfterDuplicate: bText.value,
  );
}

// ---------------------------------------------------------------------------
// Inspection helpers
// ---------------------------------------------------------------------------

/// Code-unit dump, e.g. `[0061, d83d, de00]`. Use in failure messages: two
/// strings that print identically can differ in code units.
String hex(String s) =>
    '[${s.codeUnits.map((u) => u.toRadixString(16).padLeft(4, '0')).join(', ')}]';

bool _isHigh(int u) => u >= 0xD800 && u <= 0xDBFF;

bool _isLow(int u) => u >= 0xDC00 && u <= 0xDFFF;

/// Code-unit indices holding a surrogate that is not part of a valid pair.
List<int> loneSurrogates(String s) {
  final units = s.codeUnits;
  final out = <int>[];
  for (var i = 0; i < units.length; i++) {
    final u = units[i];
    if (_isHigh(u)) {
      if (i + 1 < units.length && _isLow(units[i + 1])) {
        i++; // well-formed pair
      } else {
        out.add(i);
      }
    } else if (_isLow(u)) {
      out.add(i);
    }
  }
  return out;
}

bool isWellFormedUtf16(String s) => loneSurrogates(s).isEmpty;

/// Set of code points in [s]. Lone surrogates surface as their own scalar
/// value, which is what lets [novelCodePoints] spot a torn pair that got
/// re-paired into a character nobody typed.
Set<int> codePointsOf(String s) {
  final out = <int>{};
  final units = s.codeUnits;
  for (var i = 0; i < units.length; i++) {
    final u = units[i];
    if (_isHigh(u) && i + 1 < units.length && _isLow(units[i + 1])) {
      out.add(0x10000 + ((u - 0xD800) << 10) + (units[i + 1] - 0xDC00));
      i++;
    } else {
      out.add(u);
    }
  }
  return out;
}

/// Code points present in [result] that appear in none of the [inputs].
///
/// A merge may legitimately drop or reorder characters, but it must never
/// *synthesize* one: if a high surrogate from `😀` ends up paired with a low
/// surrogate from `😃`, the result contains an emoji no replica ever wrote.
/// That is the failure mode `isWellFormedUtf16` cannot see.
Set<int> novelCodePoints(String result, List<String> inputs) {
  final allowed = <int>{};
  for (final s in inputs) {
    allowed.addAll(codePointsOf(s));
  }
  return codePointsOf(result).difference(allowed);
}

/// Grapheme clusters in [result] that appear in none of the [inputs].
///
/// Advisory only. Unlike [novelCodePoints] this has legitimate false positives:
/// a merge can leave a *partial* cluster (a lone regional indicator, a base
/// letter whose combining mark was deleted) that no input contained as a
/// standalone cluster, without anything being wrong at the code-unit level.
/// Useful for diagnosing rendering surprises, not for proving corruption.
Set<String> novelGraphemes(String result, List<String> inputs) {
  final allowed = <String>{};
  for (final s in inputs) {
    allowed.addAll(s.characters);
  }
  return result.characters.toSet().difference(allowed);
}

/// Indices of ZWJ (U+200D) code units that are orphaned — leading, trailing,
/// or doubled — i.e. a joiner whose sequence got torn apart.
List<int> orphanZwj(String s) {
  const zwj = 0x200D;
  final units = s.codeUnits;
  final out = <int>[];
  for (var i = 0; i < units.length; i++) {
    if (units[i] != zwj) {
      continue;
    }
    final atStart = i == 0;
    final atEnd = i == units.length - 1;
    final doubled = !atEnd && units[i + 1] == zwj;
    if (atStart || atEnd || doubled) {
      out.add(i);
    }
  }
  return out;
}
