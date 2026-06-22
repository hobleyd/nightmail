import 'dart:typed_data';

import 'package:equatable/equatable.dart';

sealed class EmailDetailEvent extends Equatable {
  const EmailDetailEvent();

  @override
  List<Object?> get props => [];
}

final class EmailDetailLoadRequested extends EmailDetailEvent {
  const EmailDetailLoadRequested({required this.emailId});
  final String emailId;

  @override
  List<Object?> get props => [emailId];
}

final class EmailDetailLoadedFromEml extends EmailDetailEvent {
  const EmailDetailLoadedFromEml({required this.bytes, this.sourceId});
  final Uint8List bytes;
  final String? sourceId;

  @override
  List<Object?> get props => [bytes, sourceId];
}

final class EmailDetailCleared extends EmailDetailEvent {
  const EmailDetailCleared();
}

final class EmailDetailMergeSenderRequested extends EmailDetailEvent {
  const EmailDetailMergeSenderRequested({required this.matchAddress});

  /// The known-sender address to merge with the current email's from address.
  final String matchAddress;

  @override
  List<Object?> get props => [matchAddress];
}
