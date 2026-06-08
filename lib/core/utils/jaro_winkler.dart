import 'dart:math';

/// Returns a Jaro-Winkler similarity score in [0.0, 1.0].
/// Both inputs are lower-cased and trimmed before comparison.
/// 1.0 = identical, 0.0 = completely dissimilar.
double jaroWinkler(String s1, String s2) {
  final a = s1.toLowerCase().trim();
  final b = s2.toLowerCase().trim();

  if (a == b) return 1.0;
  if (a.isEmpty || b.isEmpty) return 0.0;

  final matchWindow = max(0, max(a.length, b.length) ~/ 2 - 1);

  final aMatched = List<bool>.filled(a.length, false);
  final bMatched = List<bool>.filled(b.length, false);

  var matches = 0;
  for (var i = 0; i < a.length; i++) {
    final start = max(0, i - matchWindow);
    final end = min(b.length - 1, i + matchWindow);
    for (var j = start; j <= end; j++) {
      if (bMatched[j] || a[i] != b[j]) continue;
      aMatched[i] = true;
      bMatched[j] = true;
      matches++;
      break;
    }
  }

  if (matches == 0) return 0.0;

  var transpositions = 0;
  var k = 0;
  for (var i = 0; i < a.length; i++) {
    if (!aMatched[i]) continue;
    while (!bMatched[k]) {
      k++;
    }
    if (a[i] != b[k]) transpositions++;
    k++;
  }

  final m = matches.toDouble();
  final jaro = (m / a.length + m / b.length + (m - transpositions / 2) / m) / 3;

  // Winkler prefix bonus — up to 4 matching prefix characters
  var prefix = 0;
  for (var i = 0; i < min(4, min(a.length, b.length)); i++) {
    if (a[i] == b[i]) {
      prefix++;
    } else {
      break;
    }
  }

  return jaro + prefix * 0.1 * (1 - jaro);
}
