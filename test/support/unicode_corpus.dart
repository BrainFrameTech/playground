/// Unicode corpus for the `change()` suite.
///
/// Each case is a `(from, to)` pair chosen because it stresses a *distinct*
/// property of `myersDiff`, which is UTF-16 code-unit based end to end
/// (`_commonPrefix`/`_commonSuffix` compare `codeUnitAt`, the SES runs on
/// `.codeUnits`, and `_coalesce` builds segments one code unit at a time).
///
/// Invisible and ambiguous characters are written as escapes on purpose: a
/// literal ZWJ or bidi control in source is unreviewable, and the analyzer
/// rejects the bidi ones outright.
library;

class ChangeCase {
  const ChangeCase(this.name, this.from, this.to, this.why);

  final String name;

  /// Text the document starts with.
  final String from;

  /// Text passed to `change()`.
  final String to;

  /// What this case is probing — printed on failure.
  final String why;

  @override
  String toString() => name;
}

/// U+1F600 GRINNING FACE — D83D DE00.
const String grin = '\u{1F600}';

/// U+1F603 SMILING FACE WITH OPEN MOUTH — D83D DE03. Shares its HIGH
/// surrogate with [grin].
const String smile = '\u{1F603}';

/// U+20000 astral CJK ideograph — D840 DC00.
const String astralCjk = '\u{20000}';

/// U+1D400 MATHEMATICAL BOLD CAPITAL A — D835 DC00. Shares its LOW surrogate
/// with [astralCjk].
const String mathA = '\u{1D400}';

/// U+200D ZERO WIDTH JOINER.
const String zwj = '\u200D';

const String man = '\u{1F468}';
const String woman = '\u{1F469}';
const String girl = '\u{1F467}';
const String boy = '\u{1F466}';
const String familyGirl = '$man$zwj$woman$zwj$girl';
const String familyBoy = '$man$zwj$woman$zwj$boy';

/// Regional indicator pairs: D+K and D+E. Which flag renders depends entirely
/// on adjacency.
const String riD = '\u{1F1E9}';
const String riK = '\u{1F1F0}';
const String riE = '\u{1F1EA}';
const String flagDk = '$riD$riK';
const String flagDe = '$riD$riE';

/// U+00E9 vs. `e` + U+0301 COMBINING ACUTE ACCENT.
const String eAcuteNfc = 'é';
const String eAcuteNfd = 'e\u0301';
const String oAcuteNfd = 'o\u0301';

const String loneHigh = '\uD83D';
const String loneLow = '\uDE00';

/// U+FFFD REPLACEMENT CHARACTER — here as *legitimate* content.
const String replacementChar = '\uFFFD';

/// U+FE0F VARIATION SELECTOR-16 (emoji presentation).
const String vs16 = '\uFE0F';

/// U+202B RIGHT-TO-LEFT EMBEDDING and U+202C POP DIRECTIONAL FORMATTING.
const String rle = '\u202B';
const String pdf = '\u202C';

/// U+2764 HEAVY BLACK HEART (BMP, text presentation by default).
const String heart = '❤';

/// U+1F44D THUMBS UP and U+1F3FD EMOJI MODIFIER FITZPATRICK TYPE-4.
const String thumbsUp = '\u{1F44D}';
const String skinTone = '\u{1F3FD}';

const List<ChangeCase> corpus = <ChangeCase>[
  ChangeCase(
    'ascii-baseline',
    'Hello World',
    'Hello Brave New World',
    'control case from the docstring; if this fails nothing else means anything',
  ),
  ChangeCase(
    'split-inside-pair',
    'a${grin}b',
    'a${smile}b',
    'common prefix ends BETWEEN the two code units of the emoji, so change() '
        'deletes and re-inserts a lone low surrogate',
  ),
  ChangeCase(
    'shared-low-surrogate',
    'x${astralCjk}y',
    'x${mathA}y',
    'the two astral chars share their LOW surrogate, so the diff matches on '
        'the trailing half instead of the leading half',
  ),
  ChangeCase(
    'reorder-astral',
    '${grin}X$mathA',
    '$mathA${grin}X',
    'reordering non-BMP chars: half-pairs get shuffled across segments',
  ),
  ChangeCase(
    'insert-between-pair-halves',
    '$grin$grin',
    '${grin}Z$grin',
    'insertion point falls at a code-unit index that is also a pair boundary',
  ),
  ChangeCase(
    'delete-whole-emoji',
    'a${grin}b',
    'ab',
    'both halves must go; a half-delete leaves a lone surrogate',
  ),
  ChangeCase(
    'emoji-only-to-empty',
    grin,
    '',
    'empty-target fast path in myersDiff',
  ),
  ChangeCase(
    'empty-to-emoji',
    '',
    'a${grin}b',
    'empty-source fast path',
  ),
  ChangeCase(
    'flag-dk-to-de',
    flagDk,
    flagDe,
    'regional indicator pair: which flag renders depends on ADJACENCY, so a '
        'code-unit-correct result can still be the wrong flag',
  ),
  ChangeCase(
    'zwj-family-girl-to-boy',
    familyGirl,
    familyBoy,
    'ZWJ sequence: diff edits the last member and can orphan a joiner',
  ),
  ChangeCase(
    'zwj-family-truncate',
    familyGirl,
    man,
    'dropping ZWJ members must not leave a trailing joiner',
  ),
  ChangeCase(
    'nfc-to-nfd',
    'caf$eAcuteNfc',
    'caf$eAcuteNfd',
    'precomposed to decomposed: the combining mark becomes its own element',
  ),
  ChangeCase(
    'nfd-to-nfc',
    'caf$eAcuteNfd',
    'caf$eAcuteNfc',
    'the reverse; base+mark collapse into one code point',
  ),
  ChangeCase(
    'combining-mark-rebase',
    '${eAcuteNfd}o',
    '${oAcuteNfd}e',
    'the combining mark must follow its new base, not stay put',
  ),
  ChangeCase(
    'literal-replacement-char',
    'x',
    'x$replacementChar',
    'U+FFFD as GENUINE content — proves the suite can tell real content from '
        'the corruption U+FFFD that the old utf8 bug produced',
  ),
  ChangeCase(
    'preserve-lone-high-surrogate',
    'x',
    'x$loneHigh',
    'unpaired surrogate in the INPUT (legal in a Dart string) must round-trip '
        'through the WTF-8 wire format unchanged',
  ),
  ChangeCase(
    'preserve-lone-low-surrogate',
    'x',
    'x$loneLow',
    'same, low half',
  ),
  ChangeCase(
    'lone-surrogate-to-real-pair',
    'a${loneHigh}b',
    'a${grin}b',
    'an unpaired surrogate becoming a valid pair: the diff sees the high half '
        'as already equal',
  ),
  ChangeCase(
    'crlf-normalize',
    'a\r\nb',
    'a\nb',
    'the boring case that breaks real editors',
  ),
  ChangeCase(
    'embedded-nul',
    'a\u0000b',
    'a\u0000\u0000b',
    'NUL must survive a length-prefixed byte format',
  ),
  ChangeCase(
    'bidi-controls',
    'start end',
    'start \u202Bright-to-left\u202C end',
    'bidi embedding controls are invisible; corruption here is silent',
  ),
  ChangeCase(
    'mixed-scripts',
    '日本語 text',
    '한국어 $grin text',
    'BMP multi-byte plus non-BMP in one edit',
  ),
  ChangeCase(
    'variation-selector',
    heart,
    '$heart$vs16',
    'appending VS16 turns a text glyph into an emoji glyph',
  ),
  ChangeCase(
    'skin-tone-modifier',
    thumbsUp,
    '$thumbsUp$skinTone',
    'two consecutive non-BMP chars where the second modifies the first',
  ),
];
