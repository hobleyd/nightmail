import 'dart:typed_data';
import 'package:equatable/equatable.dart';

import '../../../domain/entities/email.dart';
import '../../../domain/usecases/check_sender_anomaly.dart';

sealed class EmailDetailState extends Equatable {
  const EmailDetailState();

  @override
  List<Object?> get props => [];
}

final class EmailDetailInitial extends EmailDetailState {
  const EmailDetailInitial();
}

final class EmailDetailLoading extends EmailDetailState {
  const EmailDetailLoading();
}

final class EmailDetailLoaded extends EmailDetailState {
  const EmailDetailLoaded({
    required this.email,
    this.senderAnomaly,
    this.emlSource,
  });
  final Email email;
  final SenderAnomalyResult? senderAnomaly; // null = no anomaly

  /// The raw `message/rfc822` this message was parsed from, when it came from
  /// an `.eml` rather than from a provider.
  ///
  /// [Email.attachments] then carries MIME paths rather than server-side ids,
  /// so there is nothing to download them by — the bytes have to come back out
  /// of this. Without it the reading pane draws chips it cannot honour.
  final Uint8List? emlSource;

  // The bytes themselves are deliberately not in props: Equatable would
  // deep-compare a whole message on every emit, and `email` already tells two
  // of these apart. The length is enough to keep an emit from being dropped.
  @override
  List<Object?> get props => [email, senderAnomaly, emlSource?.length];
}

final class EmailDetailError extends EmailDetailState {
  const EmailDetailError({required this.message});
  final String message;

  @override
  List<Object?> get props => [message];
}
