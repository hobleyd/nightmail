import 'dart:typed_data';

import 'package:equatable/equatable.dart';

class InlineAttachment extends Equatable {
  const InlineAttachment({
    required this.contentId,
    required this.contentType,
    required this.contentBytes,
  });

  final String contentId;
  final String contentType;
  final Uint8List contentBytes;

  @override
  List<Object?> get props => [contentId, contentType];
}
