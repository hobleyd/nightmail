import 'package:equatable/equatable.dart';

sealed class Account extends Equatable {
  const Account({
    required this.id,
    required this.displayName,
    required this.emailAddress,
  });

  final String id;
  final String displayName;
  final String emailAddress;

  Account copyWith({
    String? displayName,
    String? emailAddress,
  });

  Map<String, dynamic> toJson();

  factory Account.fromJson(Map<String, dynamic> json) {
    return switch (json['type'] as String) {
      'microsoft' => MicrosoftAccount.fromJson(json),
      'gmail' => GmailAccount.fromJson(json),
      'imap' => ImapAccount.fromJson(json),
      final t => throw ArgumentError('Unknown account type: $t'),
    };
  }
}

final class MicrosoftAccount extends Account {
  const MicrosoftAccount({
    required super.id,
    required super.displayName,
    required super.emailAddress,
    required this.tenantId,
  });

  final String tenantId;

  @override
  MicrosoftAccount copyWith({
    String? displayName,
    String? emailAddress,
    String? tenantId,
  }) {
    return MicrosoftAccount(
      id: id,
      displayName: displayName ?? this.displayName,
      emailAddress: emailAddress ?? this.emailAddress,
      tenantId: tenantId ?? this.tenantId,
    );
  }

  factory MicrosoftAccount.fromJson(Map<String, dynamic> json) {
    return MicrosoftAccount(
      id: json['id'] as String,
      displayName: json['displayName'] as String,
      emailAddress: json['emailAddress'] as String,
      tenantId: json['tenantId'] as String? ?? 'common',
    );
  }

  @override
  Map<String, dynamic> toJson() => {
        'type': 'microsoft',
        'id': id,
        'displayName': displayName,
        'emailAddress': emailAddress,
        'tenantId': tenantId,
      };

  @override
  List<Object?> get props => [id, displayName, emailAddress, tenantId];
}

  final class GmailAccount extends Account {
  const GmailAccount({
    required super.id,
    required super.displayName,
    required super.emailAddress,
  });

  @override
  GmailAccount copyWith({
    String? displayName,
    String? emailAddress,
  }) {
    return GmailAccount(
      id: id,
      displayName: displayName ?? this.displayName,
      emailAddress: emailAddress ?? this.emailAddress,
    );
  }

  factory GmailAccount.fromJson(Map<String, dynamic> json) {
    return GmailAccount(
      id: json['id'] as String,
      displayName: json['displayName'] as String,
      emailAddress: json['emailAddress'] as String,
    );
  }

  @override
  Map<String, dynamic> toJson() => {
        'type': 'gmail',
        'id': id,
        'displayName': displayName,
        'emailAddress': emailAddress,
      };

  @override
  List<Object?> get props => [id, displayName, emailAddress];
}

final class ImapAccount extends Account {
  const ImapAccount({
    required super.id,
    required super.displayName,
    required super.emailAddress,
    required this.host,
    required this.port,
    required this.useSsl,
  });

  final String host;
  final int port;
  final bool useSsl;

  @override
  ImapAccount copyWith({
    String? displayName,
    String? emailAddress,
    String? host,
    int? port,
    bool? useSsl,
  }) {
    return ImapAccount(
      id: id,
      displayName: displayName ?? this.displayName,
      emailAddress: emailAddress ?? this.emailAddress,
      host: host ?? this.host,
      port: port ?? this.port,
      useSsl: useSsl ?? this.useSsl,
    );
  }

  factory ImapAccount.fromJson(Map<String, dynamic> json) {
    return ImapAccount(
      id: json['id'] as String,
      displayName: json['displayName'] as String,
      emailAddress: json['emailAddress'] as String,
      host: json['host'] as String,
      port: json['port'] as int,
      useSsl: json['useSsl'] as bool? ?? true,
    );
  }

  @override
  Map<String, dynamic> toJson() => {
        'type': 'imap',
        'id': id,
        'displayName': displayName,
        'emailAddress': emailAddress,
        'host': host,
        'port': port,
        'useSsl': useSsl,
      };

  @override
  List<Object?> get props => [id, displayName, emailAddress, host, port, useSsl];
}
