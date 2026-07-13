import 'package:equatable/equatable.dart';

class NextcloudCalendarConfig extends Equatable {
  const NextcloudCalendarConfig({
    required this.serverUrl,
    required this.username,
  });

  final String serverUrl;
  final String username;

  NextcloudCalendarConfig copyWith({String? serverUrl, String? username}) {
    return NextcloudCalendarConfig(
      serverUrl: serverUrl ?? this.serverUrl,
      username: username ?? this.username,
    );
  }

  factory NextcloudCalendarConfig.fromJson(Map<String, dynamic> json) {
    return NextcloudCalendarConfig(
      serverUrl: json['serverUrl'] as String,
      username: json['username'] as String,
    );
  }

  Map<String, dynamic> toJson() => {
        'serverUrl': serverUrl,
        'username': username,
      };

  @override
  List<Object?> get props => [serverUrl, username];
}

sealed class Account extends Equatable {
  const Account({
    required this.id,
    required this.displayName,
    required this.emailAddress,
    this.firstName = '',
    this.lastName = '',
    this.jobTitle = '',
    this.phone = '',
    this.mobile = '',
    this.address = '',
    this.signatureHtml = '',
  });

  final String id;
  final String displayName;
  final String emailAddress;
  // Profile fields used as email signature merge tags ({{first_name}} etc.)
  // and the raw signature template (with merge tags unresolved) — both
  // allocated per account rather than globally.
  final String firstName;
  final String lastName;
  final String jobTitle;
  final String phone;
  final String mobile;
  final String address;
  final String signatureHtml;

  /// The name to show as the sender when sending mail (the `From:` header
  /// display name). [displayName] is just this account's label in the
  /// account switcher/settings UI (e.g. an organization name) and is not
  /// necessarily the account holder's own name, so prefer the Profile
  /// first/last name when set.
  String get senderName {
    final full = '$firstName $lastName'.trim();
    return full.isNotEmpty ? full : displayName;
  }

  Account copyWith({
    String? displayName,
    String? emailAddress,
    String? firstName,
    String? lastName,
    String? jobTitle,
    String? phone,
    String? mobile,
    String? address,
    String? signatureHtml,
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
    super.firstName,
    super.lastName,
    super.jobTitle,
    super.phone,
    super.mobile,
    super.address,
    super.signatureHtml,
  });

  final String tenantId;

  @override
  MicrosoftAccount copyWith({
    String? displayName,
    String? emailAddress,
    String? firstName,
    String? lastName,
    String? jobTitle,
    String? phone,
    String? mobile,
    String? address,
    String? signatureHtml,
    String? tenantId,
  }) {
    return MicrosoftAccount(
      id: id,
      displayName: displayName ?? this.displayName,
      emailAddress: emailAddress ?? this.emailAddress,
      firstName: firstName ?? this.firstName,
      lastName: lastName ?? this.lastName,
      jobTitle: jobTitle ?? this.jobTitle,
      phone: phone ?? this.phone,
      mobile: mobile ?? this.mobile,
      address: address ?? this.address,
      signatureHtml: signatureHtml ?? this.signatureHtml,
      tenantId: tenantId ?? this.tenantId,
    );
  }

  factory MicrosoftAccount.fromJson(Map<String, dynamic> json) {
    return MicrosoftAccount(
      id: json['id'] as String,
      displayName: json['displayName'] as String,
      emailAddress: json['emailAddress'] as String,
      tenantId: json['tenantId'] as String? ?? 'common',
      firstName: json['firstName'] as String? ?? '',
      lastName: json['lastName'] as String? ?? '',
      jobTitle: json['jobTitle'] as String? ?? '',
      phone: json['phone'] as String? ?? '',
      mobile: json['mobile'] as String? ?? '',
      address: json['address'] as String? ?? '',
      signatureHtml: json['signatureHtml'] as String? ?? '',
    );
  }

  @override
  Map<String, dynamic> toJson() => {
        'type': 'microsoft',
        'id': id,
        'displayName': displayName,
        'emailAddress': emailAddress,
        'tenantId': tenantId,
        'firstName': firstName,
        'lastName': lastName,
        'jobTitle': jobTitle,
        'phone': phone,
        'mobile': mobile,
        'address': address,
        'signatureHtml': signatureHtml,
      };

  @override
  List<Object?> get props => [
        id,
        displayName,
        emailAddress,
        tenantId,
        firstName,
        lastName,
        jobTitle,
        phone,
        mobile,
        address,
        signatureHtml,
      ];
}

  final class GmailAccount extends Account {
  const GmailAccount({
    required super.id,
    required super.displayName,
    required super.emailAddress,
    super.firstName,
    super.lastName,
    super.jobTitle,
    super.phone,
    super.mobile,
    super.address,
    super.signatureHtml,
  });

  @override
  GmailAccount copyWith({
    String? displayName,
    String? emailAddress,
    String? firstName,
    String? lastName,
    String? jobTitle,
    String? phone,
    String? mobile,
    String? address,
    String? signatureHtml,
  }) {
    return GmailAccount(
      id: id,
      displayName: displayName ?? this.displayName,
      emailAddress: emailAddress ?? this.emailAddress,
      firstName: firstName ?? this.firstName,
      lastName: lastName ?? this.lastName,
      jobTitle: jobTitle ?? this.jobTitle,
      phone: phone ?? this.phone,
      mobile: mobile ?? this.mobile,
      address: address ?? this.address,
      signatureHtml: signatureHtml ?? this.signatureHtml,
    );
  }

  factory GmailAccount.fromJson(Map<String, dynamic> json) {
    return GmailAccount(
      id: json['id'] as String,
      displayName: json['displayName'] as String,
      emailAddress: json['emailAddress'] as String,
      firstName: json['firstName'] as String? ?? '',
      lastName: json['lastName'] as String? ?? '',
      jobTitle: json['jobTitle'] as String? ?? '',
      phone: json['phone'] as String? ?? '',
      mobile: json['mobile'] as String? ?? '',
      address: json['address'] as String? ?? '',
      signatureHtml: json['signatureHtml'] as String? ?? '',
    );
  }

  @override
  Map<String, dynamic> toJson() => {
        'type': 'gmail',
        'id': id,
        'displayName': displayName,
        'emailAddress': emailAddress,
        'firstName': firstName,
        'lastName': lastName,
        'jobTitle': jobTitle,
        'phone': phone,
        'mobile': mobile,
        'address': address,
        'signatureHtml': signatureHtml,
      };

  @override
  List<Object?> get props => [
        id,
        displayName,
        emailAddress,
        firstName,
        lastName,
        jobTitle,
        phone,
        mobile,
        address,
        signatureHtml,
      ];
}

final class ImapAccount extends Account {
  const ImapAccount({
    required super.id,
    required super.displayName,
    required super.emailAddress,
    required this.host,
    required this.port,
    required this.useSsl,
    required this.smtpHost,
    required this.smtpPort,
    required this.smtpUseSsl,
    this.nextcloudCalendarConfig,
    super.firstName,
    super.lastName,
    super.jobTitle,
    super.phone,
    super.mobile,
    super.address,
    super.signatureHtml,
  });

  final String host;
  final int port;
  final bool useSsl;
  final String smtpHost;
  final int smtpPort;
  final bool smtpUseSsl;
  final NextcloudCalendarConfig? nextcloudCalendarConfig;

  @override
  ImapAccount copyWith({
    String? displayName,
    String? emailAddress,
    String? firstName,
    String? lastName,
    String? jobTitle,
    String? phone,
    String? mobile,
    String? address,
    String? signatureHtml,
    String? host,
    int? port,
    bool? useSsl,
    String? smtpHost,
    int? smtpPort,
    bool? smtpUseSsl,
    Object? nextcloudCalendarConfig = _sentinel,
  }) {
    return ImapAccount(
      id: id,
      displayName: displayName ?? this.displayName,
      emailAddress: emailAddress ?? this.emailAddress,
      firstName: firstName ?? this.firstName,
      lastName: lastName ?? this.lastName,
      jobTitle: jobTitle ?? this.jobTitle,
      phone: phone ?? this.phone,
      mobile: mobile ?? this.mobile,
      address: address ?? this.address,
      signatureHtml: signatureHtml ?? this.signatureHtml,
      host: host ?? this.host,
      port: port ?? this.port,
      useSsl: useSsl ?? this.useSsl,
      smtpHost: smtpHost ?? this.smtpHost,
      smtpPort: smtpPort ?? this.smtpPort,
      smtpUseSsl: smtpUseSsl ?? this.smtpUseSsl,
      nextcloudCalendarConfig: nextcloudCalendarConfig == _sentinel
          ? this.nextcloudCalendarConfig
          : nextcloudCalendarConfig as NextcloudCalendarConfig?,
    );
  }

  factory ImapAccount.fromJson(Map<String, dynamic> json) {
    final imapHost = json['host'] as String;
    final calendarJson =
        json['nextcloudCalendarConfig'] as Map<String, dynamic>?;
    return ImapAccount(
      id: json['id'] as String,
      displayName: json['displayName'] as String,
      emailAddress: json['emailAddress'] as String,
      host: imapHost,
      port: json['port'] as int,
      useSsl: json['useSsl'] as bool? ?? true,
      smtpHost: json['smtpHost'] as String? ?? imapHost,
      smtpPort: json['smtpPort'] as int? ?? 587,
      smtpUseSsl: json['smtpUseSsl'] as bool? ?? false,
      nextcloudCalendarConfig: calendarJson != null
          ? NextcloudCalendarConfig.fromJson(calendarJson)
          : null,
      firstName: json['firstName'] as String? ?? '',
      lastName: json['lastName'] as String? ?? '',
      jobTitle: json['jobTitle'] as String? ?? '',
      phone: json['phone'] as String? ?? '',
      mobile: json['mobile'] as String? ?? '',
      address: json['address'] as String? ?? '',
      signatureHtml: json['signatureHtml'] as String? ?? '',
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
        'smtpHost': smtpHost,
        'smtpPort': smtpPort,
        'smtpUseSsl': smtpUseSsl,
        if (nextcloudCalendarConfig != null)
          'nextcloudCalendarConfig': nextcloudCalendarConfig!.toJson(),
        'firstName': firstName,
        'lastName': lastName,
        'jobTitle': jobTitle,
        'phone': phone,
        'mobile': mobile,
        'address': address,
        'signatureHtml': signatureHtml,
      };

  @override
  List<Object?> get props => [
        id,
        displayName,
        emailAddress,
        host,
        port,
        useSsl,
        smtpHost,
        smtpPort,
        smtpUseSsl,
        nextcloudCalendarConfig,
        firstName,
        lastName,
        jobTitle,
        phone,
        mobile,
        address,
        signatureHtml,
      ];
}

// Sentinel for distinguishing "not passed" from "explicitly null" in copyWith.
const _sentinel = Object();
