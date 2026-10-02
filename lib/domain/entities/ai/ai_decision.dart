import 'package:equatable/equatable.dart';

/// The three typed-decision primitives a System One model answers.
///
/// System One models (TypeSafe's Jev, the open Laya family) do not generate
/// text. They read a *state* and a set of typed questions and return bounded,
/// calibrated answers: a probability for a proposition ([noul]), a pick from
/// named options ([choice]), or a position on an ordered rubric ([score]).
enum AiDecisionQuestionType { noul, choice, score }

/// One typed question posed to a System One model.
///
/// Built through the named constructors so each type carries exactly the
/// criteria it needs: [AiDecisionQuestion.noul] optionally describes the
/// true/false sides, [AiDecisionQuestion.choice] names its options,
/// [AiDecisionQuestion.score] lists its ordered rubric levels.
class AiDecisionQuestion extends Equatable {
  const AiDecisionQuestion._({
    required this.type,
    required this.instructions,
    this.options = const {},
    this.levels = const [],
    this.trueDescription,
    this.falseDescription,
  });

  /// A yes/no proposition answered with P(true).
  const AiDecisionQuestion.noul({
    required String instructions,
    String? trueDescription,
    String? falseDescription,
  }) : this._(
          type: AiDecisionQuestionType.noul,
          instructions: instructions,
          trueDescription: trueDescription,
          falseDescription: falseDescription,
        );

  /// A pick from named [options] (`key → description`); the answer is one key
  /// plus a probability per key.
  const AiDecisionQuestion.choice({
    required String instructions,
    required Map<String, String> options,
  }) : this._(
          type: AiDecisionQuestionType.choice,
          instructions: instructions,
          options: options,
        );

  /// A position on the ordered rubric [levels] (index 0 = first level); the
  /// answer is the expected zero-based level plus a probability per level.
  const AiDecisionQuestion.score({
    required String instructions,
    required List<String> levels,
  }) : this._(
          type: AiDecisionQuestionType.score,
          instructions: instructions,
          levels: levels,
        );

  final AiDecisionQuestionType type;

  /// What to decide, phrased for the model (e.g. "How urgent is this?").
  final String instructions;

  /// [AiDecisionQuestionType.choice] options, `key → description`.
  final Map<String, String> options;

  /// [AiDecisionQuestionType.score] rubric levels, lowest first.
  final List<String> levels;

  /// Optional descriptions of the true / false sides of a noul question.
  final String? trueDescription;
  final String? falseDescription;

  @override
  List<Object?> get props => [
        type,
        instructions,
        options,
        levels,
        trueDescription,
        falseDescription,
      ];
}

/// A normalized typed-decision request handed to a decision-capable adapter.
///
/// [state] is the situation being judged: free text, or a JSON-like map /
/// list (e.g. `{subject, body, from}` for an email). [questions] is keyed by
/// caller-chosen ids that come back on the matching [AiDecisionAnswer].
class AiDecisionRequest extends Equatable {
  const AiDecisionRequest({
    required this.providerId,
    required this.modelId,
    required this.state,
    required this.questions,
  });

  final String providerId;
  final String modelId;

  /// `String`, `Map<String, Object?>` or `List<Object?>` — serialised as-is.
  final Object state;

  final Map<String, AiDecisionQuestion> questions;

  @override
  List<Object?> get props => [providerId, modelId, state, questions];
}

/// The model's answer to one [AiDecisionQuestion].
///
/// Which fields are populated depends on [type]: [probability] for noul,
/// [choice] + [probabilities] for choice, [score] + [legend] + [probabilities]
/// for score. [confidence] is the model's own calibrated confidence in the
/// selected answer when the provider reports one.
class AiDecisionAnswer extends Equatable {
  const AiDecisionAnswer({
    required this.type,
    this.probability,
    this.choice,
    this.score,
    this.probabilities = const {},
    this.legend = const {},
    this.confidence,
  });

  final AiDecisionQuestionType type;

  /// noul: P(true).
  final double? probability;

  /// choice: the selected option key.
  final String? choice;

  /// score: the expected zero-based rubric level (may be fractional).
  final double? score;

  /// choice: probability per option key; score: probability per level index
  /// (as a string key, matching [legend]).
  final Map<String, double> probabilities;

  /// score: level index (string) → level label.
  final Map<String, String> legend;

  final double? confidence;

  /// The most likely rubric level for a score answer (nearest to [score]),
  /// resolved through [legend]; null for other types or when unknown.
  String? get scoreLabel {
    final s = score;
    if (type != AiDecisionQuestionType.score || s == null) return null;
    return legend[s.round().toString()];
  }

  /// A compact human-readable rendering, e.g. `yes 82%`, `billing 85%`,
  /// `needs attention soon (1.4)`.
  String get summary {
    String pct(double? v) => v == null ? '?' : '${(v * 100).round()}%';
    switch (type) {
      case AiDecisionQuestionType.noul:
        final p = probability;
        if (p == null) return '?';
        return p >= 0.5 ? 'yes ${pct(p)}' : 'no ${pct(1 - p)}';
      case AiDecisionQuestionType.choice:
        final c = choice;
        if (c == null) return '?';
        final p = probabilities[c];
        return p == null ? c : '$c ${pct(p)}';
      case AiDecisionQuestionType.score:
        final s = score;
        if (s == null) return '?';
        final label = scoreLabel;
        final value = s.toStringAsFixed(1);
        return label == null ? value : '$label ($value)';
    }
  }

  @override
  List<Object?> get props => [
        type,
        probability,
        choice,
        score,
        probabilities,
        legend,
        confidence,
      ];
}

/// The full result of a typed-decision request.
class AiDecisionResponse extends Equatable {
  const AiDecisionResponse({
    required this.model,
    required this.answers,
    this.inputTokens,
    this.outputTokens,
  });

  /// The model that actually answered (providers may resolve an alias such as
  /// `jev-latest` to a concrete version).
  final String model;

  /// Answers keyed by the question ids from the request.
  final Map<String, AiDecisionAnswer> answers;

  final int? inputTokens;
  final int? outputTokens;

  @override
  List<Object?> get props => [model, answers, inputTokens, outputTokens];
}
