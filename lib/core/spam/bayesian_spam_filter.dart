import 'dart:math' as math;

const double _spamThreshold = 0.85;
const int _maxTrainedIds = 10000;

class BayesianSpamFilter {
  BayesianSpamFilter()
      : _spamWords = {},
        _hamWords = {},
        totalSpam = 0,
        totalHam = 0,
        _trainedIds = {};

  BayesianSpamFilter._({
    required Map<String, int> spamWords,
    required Map<String, int> hamWords,
    required this.totalSpam,
    required this.totalHam,
    required Set<String> trainedIds,
  })  : _spamWords = spamWords,
        _hamWords = hamWords,
        _trainedIds = trainedIds;

  final Map<String, int> _spamWords;
  final Map<String, int> _hamWords;
  int totalSpam;
  int totalHam;
  final Set<String> _trainedIds;

  /// True once at least one spam email has been trained.
  bool get hasTrainingData => totalSpam > 0;

  void trainSpam(String emailId, String text) {
    _addTrainedId(emailId);
    totalSpam++;
    for (final word in tokenize(text)) {
      _spamWords[word] = (_spamWords[word] ?? 0) + 1;
    }
  }

  /// Trains [text] as ham. No-ops if [emailId] was already trained as spam or
  /// ham so that inbox emails are not double-counted on repeated loads.
  void trainHam(String emailId, String text) {
    if (_trainedIds.contains(emailId)) return;
    _addTrainedId(emailId);
    totalHam++;
    for (final word in tokenize(text)) {
      _hamWords[word] = (_hamWords[word] ?? 0) + 1;
    }
  }

  /// Returns the probability (0.0–1.0) that [text] is spam using Naive Bayes
  /// with Laplace smoothing and numerically stable log-sum.
  double classify(String text) {
    if (totalSpam == 0 || totalHam == 0) return 0.0;
    final words = tokenize(text).toSet();
    if (words.isEmpty) return 0.0;

    final vocabSize =
        (_spamWords.keys.toSet()..addAll(_hamWords.keys)).length;

    double logSpam = math.log(totalSpam / (totalSpam + totalHam));
    double logHam = math.log(totalHam / (totalSpam + totalHam));

    for (final word in words) {
      logSpam +=
          math.log((_spamWords[word] ?? 0) + 1) -
          math.log(totalSpam + vocabSize);
      logHam +=
          math.log((_hamWords[word] ?? 0) + 1) -
          math.log(totalHam + vocabSize);
    }

    // Numerically stable normalisation: shift by the larger log-prob.
    final maxLog = math.max(logSpam, logHam);
    final eSpam = math.exp(logSpam - maxLog);
    final eHam = math.exp(logHam - maxLog);
    return eSpam / (eSpam + eHam);
  }

  bool isSpam(String text) => classify(text) >= _spamThreshold;

  static List<String> tokenize(String text) {
    return text
        .toLowerCase()
        .split(RegExp(r'[^a-z0-9]+'))
        .where((w) => w.length >= 3 && !_stopWords.contains(w))
        .take(500)
        .toList();
  }

  Map<String, dynamic> toJson() => {
        'spamWords': _spamWords,
        'hamWords': _hamWords,
        'totalSpam': totalSpam,
        'totalHam': totalHam,
        'trainedIds': _trainedIds.toList(),
      };

  factory BayesianSpamFilter.fromJson(Map<String, dynamic> json) {
    Map<String, int> _toWordMap(Object? raw) {
      final m = raw as Map? ?? {};
      return {for (final e in m.entries) e.key as String: (e.value as num).toInt()};
    }

    return BayesianSpamFilter._(
      spamWords: _toWordMap(json['spamWords']),
      hamWords: _toWordMap(json['hamWords']),
      totalSpam: (json['totalSpam'] as num?)?.toInt() ?? 0,
      totalHam: (json['totalHam'] as num?)?.toInt() ?? 0,
      trainedIds: Set<String>.from(json['trainedIds'] as List? ?? []),
    );
  }

  void _addTrainedId(String id) {
    _trainedIds.add(id);
    if (_trainedIds.length > _maxTrainedIds) {
      _trainedIds.remove(_trainedIds.first);
    }
  }
}

const _stopWords = {
  'the', 'and', 'for', 'are', 'but', 'not', 'you', 'all', 'can',
  'has', 'her', 'was', 'one', 'our', 'out', 'day', 'get', 'him',
  'his', 'how', 'its', 'let', 'new', 'now', 'old', 'see', 'she',
  'too', 'use', 'who', 'did', 'put', 'say', 'two', 'way', 'man',
  'com', 'www', 'http', 'https', 'this', 'that', 'with', 'from',
  'have', 'will', 'your', 'they', 'been', 'more', 'when', 'also',
  'into', 'than', 'then', 'over', 'just', 'like', 'some', 'what',
  'click', 'here', 'please',
};
