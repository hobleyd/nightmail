import 'package:equatable/equatable.dart';

/// Lifecycle status of a model (models.dev `status` enum).
enum AiModelStatus { alpha, beta, deprecated }

/// In-memory descriptor for a single model offered by an [AiProvider].
///
/// Maps from a models.dev model entry (see "Schema Mapping" in the AI subsystem
/// design spec). Identified by `(providerId, id)`. Polymorphic/variable JSON
/// shapes (cost tiers, reasoning options, experimental, per-model provider
/// override) are kept as plain Dart collections rather than JSON strings.
class AiModel extends Equatable {
  const AiModel({
    required this.id,
    required this.providerId,
    required this.name,
    required this.attachment,
    required this.reasoning,
    required this.toolCall,
    required this.openWeights,
    required this.releaseDate,
    required this.lastUpdated,
    required this.inputModalities,
    required this.outputModalities,
    required this.contextLimit,
    required this.outputLimit,
    this.inputLimit,
    this.temperature,
    this.structuredOutput,
    this.family,
    this.status,
    this.knowledgeRaw,
    this.costInput,
    this.costOutput,
    this.costCacheRead,
    this.costCacheWrite,
    this.costReasoning,
    this.costInputAudio,
    this.costOutputAudio,
    this.costTiers,
    this.costOver200k,
    this.reasoningOptions,
    this.experimental,
    this.providerOverride,
    this.interleavedField,
  });

  /// Model id, e.g. `claude-sonnet-4`.
  final String id;

  /// Id of the owning provider.
  final String providerId;

  /// Human-readable model name.
  final String name;

  /// Whether the model supports file attachments.
  final bool attachment;

  /// Whether the model supports reasoning.
  final bool reasoning;

  /// Whether the model supports tool/function calling.
  final bool toolCall;

  /// Whether the model has open weights.
  final bool openWeights;

  /// Release date, `YYYY-MM-DD`.
  final String releaseDate;

  /// Last updated date, `YYYY-MM-DD`.
  final String lastUpdated;

  /// Input modalities, enum `text|image|audio|video|pdf`.
  final List<String> inputModalities;

  /// Output modalities, enum `text|image|audio|video|pdf`.
  final List<String> outputModalities;

  /// Maximum context window (`limit.context`).
  final int contextLimit;

  /// Maximum output tokens (`limit.output`).
  final int outputLimit;

  /// Optional maximum input tokens (`limit.input`).
  final int? inputLimit;

  /// Whether temperature is configurable (`temperature` flag).
  final bool? temperature;

  /// Whether structured output is supported (`structured_output` flag).
  final bool? structuredOutput;

  /// Model family, e.g. `claude`.
  final String? family;

  /// Lifecycle status.
  final AiModelStatus? status;

  /// Raw knowledge cutoff string — granularity varies (`YYYY-MM` vs
  /// `YYYY-MM-DD`), so kept unparsed.
  final String? knowledgeRaw;

  /// Cost per unit for input tokens (`cost.input`).
  final double? costInput;

  /// Cost per unit for output tokens (`cost.output`).
  final double? costOutput;

  /// Cost per unit for cache reads (`cost.cache_read`).
  final double? costCacheRead;

  /// Cost per unit for cache writes (`cost.cache_write`).
  final double? costCacheWrite;

  /// Cost per unit for reasoning tokens (`cost.reasoning`).
  final double? costReasoning;

  /// Cost per unit for input audio (`cost.input_audio`).
  final double? costInputAudio;

  /// Cost per unit for output audio (`cost.output_audio`).
  final double? costOutputAudio;

  /// Variable pricing tiers (`cost.tiers`), kept as-is.
  ///
  /// Loose JSON-backed value: typed as `Object?` (not `dynamic`) so static
  /// analysis is retained while the decoded shape stays opaque.
  final List<Object?>? costTiers;

  /// Pricing override for context over 200k (`cost.context_over_200k`),
  /// kept as-is. Loose JSON-backed (`Object?` values).
  final Map<String, Object?>? costOver200k;

  /// Reasoning options (`reasoning_options`): array of
  /// `{type, min?, max?, values?}`, kept as-is. Loose JSON-backed (`Object?`).
  final List<Object?>? reasoningOptions;

  /// Experimental flags/metadata (`experimental`), kept as-is.
  /// Loose JSON-backed: `Object?` rather than `dynamic`.
  final Object? experimental;

  /// Per-model provider override (`provider`): `{npm?, api?, shape?}`,
  /// kept as-is. Loose JSON-backed (`Object?` values).
  final Map<String, Object?>? providerOverride;

  /// Normalized `interleaved` field name.
  ///
  /// `interleaved` is polymorphic (bool | `{field}`): null when false/absent,
  /// the `field` value (e.g. `reasoning_content`) when an object.
  final String? interleavedField;

  @override
  List<Object?> get props => [
        id,
        providerId,
        name,
        attachment,
        reasoning,
        toolCall,
        openWeights,
        releaseDate,
        lastUpdated,
        inputModalities,
        outputModalities,
        contextLimit,
        outputLimit,
        inputLimit,
        temperature,
        structuredOutput,
        family,
        status,
        knowledgeRaw,
        costInput,
        costOutput,
        costCacheRead,
        costCacheWrite,
        costReasoning,
        costInputAudio,
        costOutputAudio,
        costTiers,
        costOver200k,
        reasoningOptions,
        experimental,
        providerOverride,
        interleavedField,
      ];
}
