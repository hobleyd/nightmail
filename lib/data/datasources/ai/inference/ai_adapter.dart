import 'package:fpdart/fpdart.dart';

import '../../../../core/error/failures.dart';
import '../../../../domain/entities/ai/ai_chunk.dart';
import '../../../../domain/entities/ai/ai_provider.dart';
import '../../../../domain/entities/ai/ai_request.dart';
import '../../../../domain/entities/ai/ai_response.dart';

/// The single normalization boundary between the AI subsystem and a concrete
/// provider wire format.
///
/// Each adapter speaks exactly one [AiWireProtocol]. It validates input, maps an
/// [AiRequest] into the provider's wire shape, parses the response (or SSE
/// stream), and normalizes all errors into an [AiFailure]. Features above this
/// boundary never see provider-specific shapes.
///
/// Credentials and the endpoint are passed per call rather than held by the
/// adapter, so a single adapter instance serves every provider that speaks its
/// protocol (catalog providers and user BYO endpoints alike).
abstract class AiAdapter {
  /// The wire protocol this adapter implements.
  AiWireProtocol get protocol;

  /// Single-shot generation.
  ///
  /// [apiKey] is the bearer/API key for the provider, or null when the provider
  /// requires none. [baseUrl] is the resolved endpoint to send the request to.
  Future<Either<Failure, AiResponse>> run(
    AiRequest request, {
    required String? apiKey,
    required String baseUrl,
  });

  /// Token-by-token streaming generation (SSE over dio).
  ///
  /// Emits a sequence of [AiChunk] deltas; the terminal chunk carries the
  /// finish reason and usage. [apiKey] and [baseUrl] are as in [run].
  Stream<Either<Failure, AiChunk>> stream(
    AiRequest request, {
    required String? apiKey,
    required String baseUrl,
  });
}
