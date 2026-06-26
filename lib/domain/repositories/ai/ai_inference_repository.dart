import 'package:fpdart/fpdart.dart';

import '../../../core/error/failures.dart';
import '../../entities/ai/ai_chunk.dart';
import '../../entities/ai/ai_request.dart';
import '../../entities/ai/ai_response.dart';

/// Runs inference requests against the configured AI backends.
///
/// Resolves the request's model reference to a provider descriptor and wire
/// adapter, normalizing every provider's wire format and errors behind a single
/// boundary so features never see provider-specific shapes.
abstract interface class AiInferenceRepository {
  /// Single-shot generation — resolves the full response in one future.
  Future<Either<Failure, AiResponse>> run(AiRequest request);

  /// Token-by-token streaming generation (SSE over `dio`).
  ///
  /// Emits an [AiChunk] per delta; the terminal chunk carries the
  /// `finishReason` and usage. Each event is wrapped in [Either] so a mid-stream
  /// failure (e.g. [ProviderUnreachable], [RateLimited]) surfaces as a `Left`.
  Stream<Either<Failure, AiChunk>> stream(AiRequest request);
}
