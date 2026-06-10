// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'app_database.dart';

// ignore_for_file: type=lint
class $CachedEmailsTable extends CachedEmails
    with TableInfo<$CachedEmailsTable, CachedEmail> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $CachedEmailsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _emailIdMeta = const VerificationMeta(
    'emailId',
  );
  @override
  late final GeneratedColumn<String> emailId = GeneratedColumn<String>(
    'email_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _accountIdMeta = const VerificationMeta(
    'accountId',
  );
  @override
  late final GeneratedColumn<String> accountId = GeneratedColumn<String>(
    'account_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _folderIdMeta = const VerificationMeta(
    'folderId',
  );
  @override
  late final GeneratedColumn<String> folderId = GeneratedColumn<String>(
    'folder_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _isReadMeta = const VerificationMeta('isRead');
  @override
  late final GeneratedColumn<bool> isRead = GeneratedColumn<bool>(
    'is_read',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_read" IN (0, 1))',
    ),
  );
  static const VerificationMeta _hasAttachmentsMeta = const VerificationMeta(
    'hasAttachments',
  );
  @override
  late final GeneratedColumn<bool> hasAttachments = GeneratedColumn<bool>(
    'has_attachments',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("has_attachments" IN (0, 1))',
    ),
  );
  static const VerificationMeta _receivedDateTimeMsMeta =
      const VerificationMeta('receivedDateTimeMs');
  @override
  late final GeneratedColumn<int> receivedDateTimeMs = GeneratedColumn<int>(
    'received_date_time_ms',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _conversationIdMeta = const VerificationMeta(
    'conversationId',
  );
  @override
  late final GeneratedColumn<String> conversationId = GeneratedColumn<String>(
    'conversation_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _cachedAtMsMeta = const VerificationMeta(
    'cachedAtMs',
  );
  @override
  late final GeneratedColumn<int> cachedAtMs = GeneratedColumn<int>(
    'cached_at_ms',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _encryptedDataMeta = const VerificationMeta(
    'encryptedData',
  );
  @override
  late final GeneratedColumn<String> encryptedData = GeneratedColumn<String>(
    'encrypted_data',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    emailId,
    accountId,
    folderId,
    isRead,
    hasAttachments,
    receivedDateTimeMs,
    conversationId,
    cachedAtMs,
    encryptedData,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'cached_emails';
  @override
  VerificationContext validateIntegrity(
    Insertable<CachedEmail> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('email_id')) {
      context.handle(
        _emailIdMeta,
        emailId.isAcceptableOrUnknown(data['email_id']!, _emailIdMeta),
      );
    } else if (isInserting) {
      context.missing(_emailIdMeta);
    }
    if (data.containsKey('account_id')) {
      context.handle(
        _accountIdMeta,
        accountId.isAcceptableOrUnknown(data['account_id']!, _accountIdMeta),
      );
    } else if (isInserting) {
      context.missing(_accountIdMeta);
    }
    if (data.containsKey('folder_id')) {
      context.handle(
        _folderIdMeta,
        folderId.isAcceptableOrUnknown(data['folder_id']!, _folderIdMeta),
      );
    } else if (isInserting) {
      context.missing(_folderIdMeta);
    }
    if (data.containsKey('is_read')) {
      context.handle(
        _isReadMeta,
        isRead.isAcceptableOrUnknown(data['is_read']!, _isReadMeta),
      );
    } else if (isInserting) {
      context.missing(_isReadMeta);
    }
    if (data.containsKey('has_attachments')) {
      context.handle(
        _hasAttachmentsMeta,
        hasAttachments.isAcceptableOrUnknown(
          data['has_attachments']!,
          _hasAttachmentsMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_hasAttachmentsMeta);
    }
    if (data.containsKey('received_date_time_ms')) {
      context.handle(
        _receivedDateTimeMsMeta,
        receivedDateTimeMs.isAcceptableOrUnknown(
          data['received_date_time_ms']!,
          _receivedDateTimeMsMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_receivedDateTimeMsMeta);
    }
    if (data.containsKey('conversation_id')) {
      context.handle(
        _conversationIdMeta,
        conversationId.isAcceptableOrUnknown(
          data['conversation_id']!,
          _conversationIdMeta,
        ),
      );
    }
    if (data.containsKey('cached_at_ms')) {
      context.handle(
        _cachedAtMsMeta,
        cachedAtMs.isAcceptableOrUnknown(
          data['cached_at_ms']!,
          _cachedAtMsMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_cachedAtMsMeta);
    }
    if (data.containsKey('encrypted_data')) {
      context.handle(
        _encryptedDataMeta,
        encryptedData.isAcceptableOrUnknown(
          data['encrypted_data']!,
          _encryptedDataMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_encryptedDataMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {emailId, accountId};
  @override
  CachedEmail map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return CachedEmail(
      emailId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}email_id'],
      )!,
      accountId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}account_id'],
      )!,
      folderId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}folder_id'],
      )!,
      isRead: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_read'],
      )!,
      hasAttachments: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}has_attachments'],
      )!,
      receivedDateTimeMs: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}received_date_time_ms'],
      )!,
      conversationId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}conversation_id'],
      ),
      cachedAtMs: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}cached_at_ms'],
      )!,
      encryptedData: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}encrypted_data'],
      )!,
    );
  }

  @override
  $CachedEmailsTable createAlias(String alias) {
    return $CachedEmailsTable(attachedDatabase, alias);
  }
}

class CachedEmail extends DataClass implements Insertable<CachedEmail> {
  final String emailId;
  final String accountId;
  final String folderId;
  final bool isRead;
  final bool hasAttachments;
  final int receivedDateTimeMs;
  final String? conversationId;
  final int cachedAtMs;
  final String encryptedData;
  const CachedEmail({
    required this.emailId,
    required this.accountId,
    required this.folderId,
    required this.isRead,
    required this.hasAttachments,
    required this.receivedDateTimeMs,
    this.conversationId,
    required this.cachedAtMs,
    required this.encryptedData,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['email_id'] = Variable<String>(emailId);
    map['account_id'] = Variable<String>(accountId);
    map['folder_id'] = Variable<String>(folderId);
    map['is_read'] = Variable<bool>(isRead);
    map['has_attachments'] = Variable<bool>(hasAttachments);
    map['received_date_time_ms'] = Variable<int>(receivedDateTimeMs);
    if (!nullToAbsent || conversationId != null) {
      map['conversation_id'] = Variable<String>(conversationId);
    }
    map['cached_at_ms'] = Variable<int>(cachedAtMs);
    map['encrypted_data'] = Variable<String>(encryptedData);
    return map;
  }

  CachedEmailsCompanion toCompanion(bool nullToAbsent) {
    return CachedEmailsCompanion(
      emailId: Value(emailId),
      accountId: Value(accountId),
      folderId: Value(folderId),
      isRead: Value(isRead),
      hasAttachments: Value(hasAttachments),
      receivedDateTimeMs: Value(receivedDateTimeMs),
      conversationId: conversationId == null && nullToAbsent
          ? const Value.absent()
          : Value(conversationId),
      cachedAtMs: Value(cachedAtMs),
      encryptedData: Value(encryptedData),
    );
  }

  factory CachedEmail.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return CachedEmail(
      emailId: serializer.fromJson<String>(json['emailId']),
      accountId: serializer.fromJson<String>(json['accountId']),
      folderId: serializer.fromJson<String>(json['folderId']),
      isRead: serializer.fromJson<bool>(json['isRead']),
      hasAttachments: serializer.fromJson<bool>(json['hasAttachments']),
      receivedDateTimeMs: serializer.fromJson<int>(json['receivedDateTimeMs']),
      conversationId: serializer.fromJson<String?>(json['conversationId']),
      cachedAtMs: serializer.fromJson<int>(json['cachedAtMs']),
      encryptedData: serializer.fromJson<String>(json['encryptedData']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'emailId': serializer.toJson<String>(emailId),
      'accountId': serializer.toJson<String>(accountId),
      'folderId': serializer.toJson<String>(folderId),
      'isRead': serializer.toJson<bool>(isRead),
      'hasAttachments': serializer.toJson<bool>(hasAttachments),
      'receivedDateTimeMs': serializer.toJson<int>(receivedDateTimeMs),
      'conversationId': serializer.toJson<String?>(conversationId),
      'cachedAtMs': serializer.toJson<int>(cachedAtMs),
      'encryptedData': serializer.toJson<String>(encryptedData),
    };
  }

  CachedEmail copyWith({
    String? emailId,
    String? accountId,
    String? folderId,
    bool? isRead,
    bool? hasAttachments,
    int? receivedDateTimeMs,
    Value<String?> conversationId = const Value.absent(),
    int? cachedAtMs,
    String? encryptedData,
  }) => CachedEmail(
    emailId: emailId ?? this.emailId,
    accountId: accountId ?? this.accountId,
    folderId: folderId ?? this.folderId,
    isRead: isRead ?? this.isRead,
    hasAttachments: hasAttachments ?? this.hasAttachments,
    receivedDateTimeMs: receivedDateTimeMs ?? this.receivedDateTimeMs,
    conversationId: conversationId.present
        ? conversationId.value
        : this.conversationId,
    cachedAtMs: cachedAtMs ?? this.cachedAtMs,
    encryptedData: encryptedData ?? this.encryptedData,
  );
  CachedEmail copyWithCompanion(CachedEmailsCompanion data) {
    return CachedEmail(
      emailId: data.emailId.present ? data.emailId.value : this.emailId,
      accountId: data.accountId.present ? data.accountId.value : this.accountId,
      folderId: data.folderId.present ? data.folderId.value : this.folderId,
      isRead: data.isRead.present ? data.isRead.value : this.isRead,
      hasAttachments: data.hasAttachments.present
          ? data.hasAttachments.value
          : this.hasAttachments,
      receivedDateTimeMs: data.receivedDateTimeMs.present
          ? data.receivedDateTimeMs.value
          : this.receivedDateTimeMs,
      conversationId: data.conversationId.present
          ? data.conversationId.value
          : this.conversationId,
      cachedAtMs: data.cachedAtMs.present
          ? data.cachedAtMs.value
          : this.cachedAtMs,
      encryptedData: data.encryptedData.present
          ? data.encryptedData.value
          : this.encryptedData,
    );
  }

  @override
  String toString() {
    return (StringBuffer('CachedEmail(')
          ..write('emailId: $emailId, ')
          ..write('accountId: $accountId, ')
          ..write('folderId: $folderId, ')
          ..write('isRead: $isRead, ')
          ..write('hasAttachments: $hasAttachments, ')
          ..write('receivedDateTimeMs: $receivedDateTimeMs, ')
          ..write('conversationId: $conversationId, ')
          ..write('cachedAtMs: $cachedAtMs, ')
          ..write('encryptedData: $encryptedData')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    emailId,
    accountId,
    folderId,
    isRead,
    hasAttachments,
    receivedDateTimeMs,
    conversationId,
    cachedAtMs,
    encryptedData,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CachedEmail &&
          other.emailId == this.emailId &&
          other.accountId == this.accountId &&
          other.folderId == this.folderId &&
          other.isRead == this.isRead &&
          other.hasAttachments == this.hasAttachments &&
          other.receivedDateTimeMs == this.receivedDateTimeMs &&
          other.conversationId == this.conversationId &&
          other.cachedAtMs == this.cachedAtMs &&
          other.encryptedData == this.encryptedData);
}

class CachedEmailsCompanion extends UpdateCompanion<CachedEmail> {
  final Value<String> emailId;
  final Value<String> accountId;
  final Value<String> folderId;
  final Value<bool> isRead;
  final Value<bool> hasAttachments;
  final Value<int> receivedDateTimeMs;
  final Value<String?> conversationId;
  final Value<int> cachedAtMs;
  final Value<String> encryptedData;
  final Value<int> rowid;
  const CachedEmailsCompanion({
    this.emailId = const Value.absent(),
    this.accountId = const Value.absent(),
    this.folderId = const Value.absent(),
    this.isRead = const Value.absent(),
    this.hasAttachments = const Value.absent(),
    this.receivedDateTimeMs = const Value.absent(),
    this.conversationId = const Value.absent(),
    this.cachedAtMs = const Value.absent(),
    this.encryptedData = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  CachedEmailsCompanion.insert({
    required String emailId,
    required String accountId,
    required String folderId,
    required bool isRead,
    required bool hasAttachments,
    required int receivedDateTimeMs,
    this.conversationId = const Value.absent(),
    required int cachedAtMs,
    required String encryptedData,
    this.rowid = const Value.absent(),
  }) : emailId = Value(emailId),
       accountId = Value(accountId),
       folderId = Value(folderId),
       isRead = Value(isRead),
       hasAttachments = Value(hasAttachments),
       receivedDateTimeMs = Value(receivedDateTimeMs),
       cachedAtMs = Value(cachedAtMs),
       encryptedData = Value(encryptedData);
  static Insertable<CachedEmail> custom({
    Expression<String>? emailId,
    Expression<String>? accountId,
    Expression<String>? folderId,
    Expression<bool>? isRead,
    Expression<bool>? hasAttachments,
    Expression<int>? receivedDateTimeMs,
    Expression<String>? conversationId,
    Expression<int>? cachedAtMs,
    Expression<String>? encryptedData,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (emailId != null) 'email_id': emailId,
      if (accountId != null) 'account_id': accountId,
      if (folderId != null) 'folder_id': folderId,
      if (isRead != null) 'is_read': isRead,
      if (hasAttachments != null) 'has_attachments': hasAttachments,
      if (receivedDateTimeMs != null)
        'received_date_time_ms': receivedDateTimeMs,
      if (conversationId != null) 'conversation_id': conversationId,
      if (cachedAtMs != null) 'cached_at_ms': cachedAtMs,
      if (encryptedData != null) 'encrypted_data': encryptedData,
      if (rowid != null) 'rowid': rowid,
    });
  }

  CachedEmailsCompanion copyWith({
    Value<String>? emailId,
    Value<String>? accountId,
    Value<String>? folderId,
    Value<bool>? isRead,
    Value<bool>? hasAttachments,
    Value<int>? receivedDateTimeMs,
    Value<String?>? conversationId,
    Value<int>? cachedAtMs,
    Value<String>? encryptedData,
    Value<int>? rowid,
  }) {
    return CachedEmailsCompanion(
      emailId: emailId ?? this.emailId,
      accountId: accountId ?? this.accountId,
      folderId: folderId ?? this.folderId,
      isRead: isRead ?? this.isRead,
      hasAttachments: hasAttachments ?? this.hasAttachments,
      receivedDateTimeMs: receivedDateTimeMs ?? this.receivedDateTimeMs,
      conversationId: conversationId ?? this.conversationId,
      cachedAtMs: cachedAtMs ?? this.cachedAtMs,
      encryptedData: encryptedData ?? this.encryptedData,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (emailId.present) {
      map['email_id'] = Variable<String>(emailId.value);
    }
    if (accountId.present) {
      map['account_id'] = Variable<String>(accountId.value);
    }
    if (folderId.present) {
      map['folder_id'] = Variable<String>(folderId.value);
    }
    if (isRead.present) {
      map['is_read'] = Variable<bool>(isRead.value);
    }
    if (hasAttachments.present) {
      map['has_attachments'] = Variable<bool>(hasAttachments.value);
    }
    if (receivedDateTimeMs.present) {
      map['received_date_time_ms'] = Variable<int>(receivedDateTimeMs.value);
    }
    if (conversationId.present) {
      map['conversation_id'] = Variable<String>(conversationId.value);
    }
    if (cachedAtMs.present) {
      map['cached_at_ms'] = Variable<int>(cachedAtMs.value);
    }
    if (encryptedData.present) {
      map['encrypted_data'] = Variable<String>(encryptedData.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('CachedEmailsCompanion(')
          ..write('emailId: $emailId, ')
          ..write('accountId: $accountId, ')
          ..write('folderId: $folderId, ')
          ..write('isRead: $isRead, ')
          ..write('hasAttachments: $hasAttachments, ')
          ..write('receivedDateTimeMs: $receivedDateTimeMs, ')
          ..write('conversationId: $conversationId, ')
          ..write('cachedAtMs: $cachedAtMs, ')
          ..write('encryptedData: $encryptedData, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $KnownSendersTable extends KnownSenders
    with TableInfo<$KnownSendersTable, KnownSender> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $KnownSendersTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _accountIdMeta = const VerificationMeta(
    'accountId',
  );
  @override
  late final GeneratedColumn<String> accountId = GeneratedColumn<String>(
    'account_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _addressMeta = const VerificationMeta(
    'address',
  );
  @override
  late final GeneratedColumn<String> address = GeneratedColumn<String>(
    'address',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [accountId, address, name];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'known_senders';
  @override
  VerificationContext validateIntegrity(
    Insertable<KnownSender> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('account_id')) {
      context.handle(
        _accountIdMeta,
        accountId.isAcceptableOrUnknown(data['account_id']!, _accountIdMeta),
      );
    } else if (isInserting) {
      context.missing(_accountIdMeta);
    }
    if (data.containsKey('address')) {
      context.handle(
        _addressMeta,
        address.isAcceptableOrUnknown(data['address']!, _addressMeta),
      );
    } else if (isInserting) {
      context.missing(_addressMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {accountId, address};
  @override
  KnownSender map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return KnownSender(
      accountId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}account_id'],
      )!,
      address: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}address'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
    );
  }

  @override
  $KnownSendersTable createAlias(String alias) {
    return $KnownSendersTable(attachedDatabase, alias);
  }
}

class KnownSender extends DataClass implements Insertable<KnownSender> {
  final String accountId;
  final String address;
  final String name;
  const KnownSender({
    required this.accountId,
    required this.address,
    required this.name,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['account_id'] = Variable<String>(accountId);
    map['address'] = Variable<String>(address);
    map['name'] = Variable<String>(name);
    return map;
  }

  KnownSendersCompanion toCompanion(bool nullToAbsent) {
    return KnownSendersCompanion(
      accountId: Value(accountId),
      address: Value(address),
      name: Value(name),
    );
  }

  factory KnownSender.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return KnownSender(
      accountId: serializer.fromJson<String>(json['accountId']),
      address: serializer.fromJson<String>(json['address']),
      name: serializer.fromJson<String>(json['name']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'accountId': serializer.toJson<String>(accountId),
      'address': serializer.toJson<String>(address),
      'name': serializer.toJson<String>(name),
    };
  }

  KnownSender copyWith({String? accountId, String? address, String? name}) =>
      KnownSender(
        accountId: accountId ?? this.accountId,
        address: address ?? this.address,
        name: name ?? this.name,
      );
  KnownSender copyWithCompanion(KnownSendersCompanion data) {
    return KnownSender(
      accountId: data.accountId.present ? data.accountId.value : this.accountId,
      address: data.address.present ? data.address.value : this.address,
      name: data.name.present ? data.name.value : this.name,
    );
  }

  @override
  String toString() {
    return (StringBuffer('KnownSender(')
          ..write('accountId: $accountId, ')
          ..write('address: $address, ')
          ..write('name: $name')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(accountId, address, name);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is KnownSender &&
          other.accountId == this.accountId &&
          other.address == this.address &&
          other.name == this.name);
}

class KnownSendersCompanion extends UpdateCompanion<KnownSender> {
  final Value<String> accountId;
  final Value<String> address;
  final Value<String> name;
  final Value<int> rowid;
  const KnownSendersCompanion({
    this.accountId = const Value.absent(),
    this.address = const Value.absent(),
    this.name = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  KnownSendersCompanion.insert({
    required String accountId,
    required String address,
    required String name,
    this.rowid = const Value.absent(),
  }) : accountId = Value(accountId),
       address = Value(address),
       name = Value(name);
  static Insertable<KnownSender> custom({
    Expression<String>? accountId,
    Expression<String>? address,
    Expression<String>? name,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (accountId != null) 'account_id': accountId,
      if (address != null) 'address': address,
      if (name != null) 'name': name,
      if (rowid != null) 'rowid': rowid,
    });
  }

  KnownSendersCompanion copyWith({
    Value<String>? accountId,
    Value<String>? address,
    Value<String>? name,
    Value<int>? rowid,
  }) {
    return KnownSendersCompanion(
      accountId: accountId ?? this.accountId,
      address: address ?? this.address,
      name: name ?? this.name,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (accountId.present) {
      map['account_id'] = Variable<String>(accountId.value);
    }
    if (address.present) {
      map['address'] = Variable<String>(address.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('KnownSendersCompanion(')
          ..write('accountId: $accountId, ')
          ..write('address: $address, ')
          ..write('name: $name, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $DeltaSyncTokensTable extends DeltaSyncTokens
    with TableInfo<$DeltaSyncTokensTable, DeltaSyncToken> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $DeltaSyncTokensTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _accountIdMeta = const VerificationMeta(
    'accountId',
  );
  @override
  late final GeneratedColumn<String> accountId = GeneratedColumn<String>(
    'account_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _folderIdMeta = const VerificationMeta(
    'folderId',
  );
  @override
  late final GeneratedColumn<String> folderId = GeneratedColumn<String>(
    'folder_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _deltaLinkMeta = const VerificationMeta(
    'deltaLink',
  );
  @override
  late final GeneratedColumn<String> deltaLink = GeneratedColumn<String>(
    'delta_link',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [accountId, folderId, deltaLink];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'delta_sync_tokens';
  @override
  VerificationContext validateIntegrity(
    Insertable<DeltaSyncToken> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('account_id')) {
      context.handle(
        _accountIdMeta,
        accountId.isAcceptableOrUnknown(data['account_id']!, _accountIdMeta),
      );
    } else if (isInserting) {
      context.missing(_accountIdMeta);
    }
    if (data.containsKey('folder_id')) {
      context.handle(
        _folderIdMeta,
        folderId.isAcceptableOrUnknown(data['folder_id']!, _folderIdMeta),
      );
    } else if (isInserting) {
      context.missing(_folderIdMeta);
    }
    if (data.containsKey('delta_link')) {
      context.handle(
        _deltaLinkMeta,
        deltaLink.isAcceptableOrUnknown(data['delta_link']!, _deltaLinkMeta),
      );
    } else if (isInserting) {
      context.missing(_deltaLinkMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {accountId, folderId};
  @override
  DeltaSyncToken map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return DeltaSyncToken(
      accountId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}account_id'],
      )!,
      folderId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}folder_id'],
      )!,
      deltaLink: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}delta_link'],
      )!,
    );
  }

  @override
  $DeltaSyncTokensTable createAlias(String alias) {
    return $DeltaSyncTokensTable(attachedDatabase, alias);
  }
}

class DeltaSyncToken extends DataClass implements Insertable<DeltaSyncToken> {
  final String accountId;
  final String folderId;
  final String deltaLink;
  const DeltaSyncToken({
    required this.accountId,
    required this.folderId,
    required this.deltaLink,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['account_id'] = Variable<String>(accountId);
    map['folder_id'] = Variable<String>(folderId);
    map['delta_link'] = Variable<String>(deltaLink);
    return map;
  }

  DeltaSyncTokensCompanion toCompanion(bool nullToAbsent) {
    return DeltaSyncTokensCompanion(
      accountId: Value(accountId),
      folderId: Value(folderId),
      deltaLink: Value(deltaLink),
    );
  }

  factory DeltaSyncToken.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return DeltaSyncToken(
      accountId: serializer.fromJson<String>(json['accountId']),
      folderId: serializer.fromJson<String>(json['folderId']),
      deltaLink: serializer.fromJson<String>(json['deltaLink']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'accountId': serializer.toJson<String>(accountId),
      'folderId': serializer.toJson<String>(folderId),
      'deltaLink': serializer.toJson<String>(deltaLink),
    };
  }

  DeltaSyncToken copyWith({
    String? accountId,
    String? folderId,
    String? deltaLink,
  }) => DeltaSyncToken(
    accountId: accountId ?? this.accountId,
    folderId: folderId ?? this.folderId,
    deltaLink: deltaLink ?? this.deltaLink,
  );
  DeltaSyncToken copyWithCompanion(DeltaSyncTokensCompanion data) {
    return DeltaSyncToken(
      accountId: data.accountId.present ? data.accountId.value : this.accountId,
      folderId: data.folderId.present ? data.folderId.value : this.folderId,
      deltaLink: data.deltaLink.present ? data.deltaLink.value : this.deltaLink,
    );
  }

  @override
  String toString() {
    return (StringBuffer('DeltaSyncToken(')
          ..write('accountId: $accountId, ')
          ..write('folderId: $folderId, ')
          ..write('deltaLink: $deltaLink')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(accountId, folderId, deltaLink);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DeltaSyncToken &&
          other.accountId == this.accountId &&
          other.folderId == this.folderId &&
          other.deltaLink == this.deltaLink);
}

class DeltaSyncTokensCompanion extends UpdateCompanion<DeltaSyncToken> {
  final Value<String> accountId;
  final Value<String> folderId;
  final Value<String> deltaLink;
  final Value<int> rowid;
  const DeltaSyncTokensCompanion({
    this.accountId = const Value.absent(),
    this.folderId = const Value.absent(),
    this.deltaLink = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  DeltaSyncTokensCompanion.insert({
    required String accountId,
    required String folderId,
    required String deltaLink,
    this.rowid = const Value.absent(),
  }) : accountId = Value(accountId),
       folderId = Value(folderId),
       deltaLink = Value(deltaLink);
  static Insertable<DeltaSyncToken> custom({
    Expression<String>? accountId,
    Expression<String>? folderId,
    Expression<String>? deltaLink,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (accountId != null) 'account_id': accountId,
      if (folderId != null) 'folder_id': folderId,
      if (deltaLink != null) 'delta_link': deltaLink,
      if (rowid != null) 'rowid': rowid,
    });
  }

  DeltaSyncTokensCompanion copyWith({
    Value<String>? accountId,
    Value<String>? folderId,
    Value<String>? deltaLink,
    Value<int>? rowid,
  }) {
    return DeltaSyncTokensCompanion(
      accountId: accountId ?? this.accountId,
      folderId: folderId ?? this.folderId,
      deltaLink: deltaLink ?? this.deltaLink,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (accountId.present) {
      map['account_id'] = Variable<String>(accountId.value);
    }
    if (folderId.present) {
      map['folder_id'] = Variable<String>(folderId.value);
    }
    if (deltaLink.present) {
      map['delta_link'] = Variable<String>(deltaLink.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('DeltaSyncTokensCompanion(')
          ..write('accountId: $accountId, ')
          ..write('folderId: $folderId, ')
          ..write('deltaLink: $deltaLink, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $CachedEmailsTable cachedEmails = $CachedEmailsTable(this);
  late final $KnownSendersTable knownSenders = $KnownSendersTable(this);
  late final $DeltaSyncTokensTable deltaSyncTokens = $DeltaSyncTokensTable(
    this,
  );
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    cachedEmails,
    knownSenders,
    deltaSyncTokens,
  ];
}

typedef $$CachedEmailsTableCreateCompanionBuilder =
    CachedEmailsCompanion Function({
      required String emailId,
      required String accountId,
      required String folderId,
      required bool isRead,
      required bool hasAttachments,
      required int receivedDateTimeMs,
      Value<String?> conversationId,
      required int cachedAtMs,
      required String encryptedData,
      Value<int> rowid,
    });
typedef $$CachedEmailsTableUpdateCompanionBuilder =
    CachedEmailsCompanion Function({
      Value<String> emailId,
      Value<String> accountId,
      Value<String> folderId,
      Value<bool> isRead,
      Value<bool> hasAttachments,
      Value<int> receivedDateTimeMs,
      Value<String?> conversationId,
      Value<int> cachedAtMs,
      Value<String> encryptedData,
      Value<int> rowid,
    });

class $$CachedEmailsTableFilterComposer
    extends Composer<_$AppDatabase, $CachedEmailsTable> {
  $$CachedEmailsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get emailId => $composableBuilder(
    column: $table.emailId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get accountId => $composableBuilder(
    column: $table.accountId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get folderId => $composableBuilder(
    column: $table.folderId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isRead => $composableBuilder(
    column: $table.isRead,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get hasAttachments => $composableBuilder(
    column: $table.hasAttachments,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get receivedDateTimeMs => $composableBuilder(
    column: $table.receivedDateTimeMs,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get conversationId => $composableBuilder(
    column: $table.conversationId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get cachedAtMs => $composableBuilder(
    column: $table.cachedAtMs,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get encryptedData => $composableBuilder(
    column: $table.encryptedData,
    builder: (column) => ColumnFilters(column),
  );
}

class $$CachedEmailsTableOrderingComposer
    extends Composer<_$AppDatabase, $CachedEmailsTable> {
  $$CachedEmailsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get emailId => $composableBuilder(
    column: $table.emailId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get accountId => $composableBuilder(
    column: $table.accountId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get folderId => $composableBuilder(
    column: $table.folderId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isRead => $composableBuilder(
    column: $table.isRead,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get hasAttachments => $composableBuilder(
    column: $table.hasAttachments,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get receivedDateTimeMs => $composableBuilder(
    column: $table.receivedDateTimeMs,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get conversationId => $composableBuilder(
    column: $table.conversationId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get cachedAtMs => $composableBuilder(
    column: $table.cachedAtMs,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get encryptedData => $composableBuilder(
    column: $table.encryptedData,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$CachedEmailsTableAnnotationComposer
    extends Composer<_$AppDatabase, $CachedEmailsTable> {
  $$CachedEmailsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get emailId =>
      $composableBuilder(column: $table.emailId, builder: (column) => column);

  GeneratedColumn<String> get accountId =>
      $composableBuilder(column: $table.accountId, builder: (column) => column);

  GeneratedColumn<String> get folderId =>
      $composableBuilder(column: $table.folderId, builder: (column) => column);

  GeneratedColumn<bool> get isRead =>
      $composableBuilder(column: $table.isRead, builder: (column) => column);

  GeneratedColumn<bool> get hasAttachments => $composableBuilder(
    column: $table.hasAttachments,
    builder: (column) => column,
  );

  GeneratedColumn<int> get receivedDateTimeMs => $composableBuilder(
    column: $table.receivedDateTimeMs,
    builder: (column) => column,
  );

  GeneratedColumn<String> get conversationId => $composableBuilder(
    column: $table.conversationId,
    builder: (column) => column,
  );

  GeneratedColumn<int> get cachedAtMs => $composableBuilder(
    column: $table.cachedAtMs,
    builder: (column) => column,
  );

  GeneratedColumn<String> get encryptedData => $composableBuilder(
    column: $table.encryptedData,
    builder: (column) => column,
  );
}

class $$CachedEmailsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $CachedEmailsTable,
          CachedEmail,
          $$CachedEmailsTableFilterComposer,
          $$CachedEmailsTableOrderingComposer,
          $$CachedEmailsTableAnnotationComposer,
          $$CachedEmailsTableCreateCompanionBuilder,
          $$CachedEmailsTableUpdateCompanionBuilder,
          (
            CachedEmail,
            BaseReferences<_$AppDatabase, $CachedEmailsTable, CachedEmail>,
          ),
          CachedEmail,
          PrefetchHooks Function()
        > {
  $$CachedEmailsTableTableManager(_$AppDatabase db, $CachedEmailsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$CachedEmailsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$CachedEmailsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$CachedEmailsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> emailId = const Value.absent(),
                Value<String> accountId = const Value.absent(),
                Value<String> folderId = const Value.absent(),
                Value<bool> isRead = const Value.absent(),
                Value<bool> hasAttachments = const Value.absent(),
                Value<int> receivedDateTimeMs = const Value.absent(),
                Value<String?> conversationId = const Value.absent(),
                Value<int> cachedAtMs = const Value.absent(),
                Value<String> encryptedData = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => CachedEmailsCompanion(
                emailId: emailId,
                accountId: accountId,
                folderId: folderId,
                isRead: isRead,
                hasAttachments: hasAttachments,
                receivedDateTimeMs: receivedDateTimeMs,
                conversationId: conversationId,
                cachedAtMs: cachedAtMs,
                encryptedData: encryptedData,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String emailId,
                required String accountId,
                required String folderId,
                required bool isRead,
                required bool hasAttachments,
                required int receivedDateTimeMs,
                Value<String?> conversationId = const Value.absent(),
                required int cachedAtMs,
                required String encryptedData,
                Value<int> rowid = const Value.absent(),
              }) => CachedEmailsCompanion.insert(
                emailId: emailId,
                accountId: accountId,
                folderId: folderId,
                isRead: isRead,
                hasAttachments: hasAttachments,
                receivedDateTimeMs: receivedDateTimeMs,
                conversationId: conversationId,
                cachedAtMs: cachedAtMs,
                encryptedData: encryptedData,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$CachedEmailsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $CachedEmailsTable,
      CachedEmail,
      $$CachedEmailsTableFilterComposer,
      $$CachedEmailsTableOrderingComposer,
      $$CachedEmailsTableAnnotationComposer,
      $$CachedEmailsTableCreateCompanionBuilder,
      $$CachedEmailsTableUpdateCompanionBuilder,
      (
        CachedEmail,
        BaseReferences<_$AppDatabase, $CachedEmailsTable, CachedEmail>,
      ),
      CachedEmail,
      PrefetchHooks Function()
    >;
typedef $$KnownSendersTableCreateCompanionBuilder =
    KnownSendersCompanion Function({
      required String accountId,
      required String address,
      required String name,
      Value<int> rowid,
    });
typedef $$KnownSendersTableUpdateCompanionBuilder =
    KnownSendersCompanion Function({
      Value<String> accountId,
      Value<String> address,
      Value<String> name,
      Value<int> rowid,
    });

class $$KnownSendersTableFilterComposer
    extends Composer<_$AppDatabase, $KnownSendersTable> {
  $$KnownSendersTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get accountId => $composableBuilder(
    column: $table.accountId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get address => $composableBuilder(
    column: $table.address,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );
}

class $$KnownSendersTableOrderingComposer
    extends Composer<_$AppDatabase, $KnownSendersTable> {
  $$KnownSendersTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get accountId => $composableBuilder(
    column: $table.accountId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get address => $composableBuilder(
    column: $table.address,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$KnownSendersTableAnnotationComposer
    extends Composer<_$AppDatabase, $KnownSendersTable> {
  $$KnownSendersTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get accountId =>
      $composableBuilder(column: $table.accountId, builder: (column) => column);

  GeneratedColumn<String> get address =>
      $composableBuilder(column: $table.address, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);
}

class $$KnownSendersTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $KnownSendersTable,
          KnownSender,
          $$KnownSendersTableFilterComposer,
          $$KnownSendersTableOrderingComposer,
          $$KnownSendersTableAnnotationComposer,
          $$KnownSendersTableCreateCompanionBuilder,
          $$KnownSendersTableUpdateCompanionBuilder,
          (
            KnownSender,
            BaseReferences<_$AppDatabase, $KnownSendersTable, KnownSender>,
          ),
          KnownSender,
          PrefetchHooks Function()
        > {
  $$KnownSendersTableTableManager(_$AppDatabase db, $KnownSendersTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$KnownSendersTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$KnownSendersTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$KnownSendersTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> accountId = const Value.absent(),
                Value<String> address = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => KnownSendersCompanion(
                accountId: accountId,
                address: address,
                name: name,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String accountId,
                required String address,
                required String name,
                Value<int> rowid = const Value.absent(),
              }) => KnownSendersCompanion.insert(
                accountId: accountId,
                address: address,
                name: name,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$KnownSendersTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $KnownSendersTable,
      KnownSender,
      $$KnownSendersTableFilterComposer,
      $$KnownSendersTableOrderingComposer,
      $$KnownSendersTableAnnotationComposer,
      $$KnownSendersTableCreateCompanionBuilder,
      $$KnownSendersTableUpdateCompanionBuilder,
      (
        KnownSender,
        BaseReferences<_$AppDatabase, $KnownSendersTable, KnownSender>,
      ),
      KnownSender,
      PrefetchHooks Function()
    >;
typedef $$DeltaSyncTokensTableCreateCompanionBuilder =
    DeltaSyncTokensCompanion Function({
      required String accountId,
      required String folderId,
      required String deltaLink,
      Value<int> rowid,
    });
typedef $$DeltaSyncTokensTableUpdateCompanionBuilder =
    DeltaSyncTokensCompanion Function({
      Value<String> accountId,
      Value<String> folderId,
      Value<String> deltaLink,
      Value<int> rowid,
    });

class $$DeltaSyncTokensTableFilterComposer
    extends Composer<_$AppDatabase, $DeltaSyncTokensTable> {
  $$DeltaSyncTokensTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get accountId => $composableBuilder(
    column: $table.accountId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get folderId => $composableBuilder(
    column: $table.folderId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get deltaLink => $composableBuilder(
    column: $table.deltaLink,
    builder: (column) => ColumnFilters(column),
  );
}

class $$DeltaSyncTokensTableOrderingComposer
    extends Composer<_$AppDatabase, $DeltaSyncTokensTable> {
  $$DeltaSyncTokensTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get accountId => $composableBuilder(
    column: $table.accountId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get folderId => $composableBuilder(
    column: $table.folderId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get deltaLink => $composableBuilder(
    column: $table.deltaLink,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$DeltaSyncTokensTableAnnotationComposer
    extends Composer<_$AppDatabase, $DeltaSyncTokensTable> {
  $$DeltaSyncTokensTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get accountId =>
      $composableBuilder(column: $table.accountId, builder: (column) => column);

  GeneratedColumn<String> get folderId =>
      $composableBuilder(column: $table.folderId, builder: (column) => column);

  GeneratedColumn<String> get deltaLink =>
      $composableBuilder(column: $table.deltaLink, builder: (column) => column);
}

class $$DeltaSyncTokensTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $DeltaSyncTokensTable,
          DeltaSyncToken,
          $$DeltaSyncTokensTableFilterComposer,
          $$DeltaSyncTokensTableOrderingComposer,
          $$DeltaSyncTokensTableAnnotationComposer,
          $$DeltaSyncTokensTableCreateCompanionBuilder,
          $$DeltaSyncTokensTableUpdateCompanionBuilder,
          (
            DeltaSyncToken,
            BaseReferences<
              _$AppDatabase,
              $DeltaSyncTokensTable,
              DeltaSyncToken
            >,
          ),
          DeltaSyncToken,
          PrefetchHooks Function()
        > {
  $$DeltaSyncTokensTableTableManager(
    _$AppDatabase db,
    $DeltaSyncTokensTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$DeltaSyncTokensTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$DeltaSyncTokensTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$DeltaSyncTokensTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> accountId = const Value.absent(),
                Value<String> folderId = const Value.absent(),
                Value<String> deltaLink = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => DeltaSyncTokensCompanion(
                accountId: accountId,
                folderId: folderId,
                deltaLink: deltaLink,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String accountId,
                required String folderId,
                required String deltaLink,
                Value<int> rowid = const Value.absent(),
              }) => DeltaSyncTokensCompanion.insert(
                accountId: accountId,
                folderId: folderId,
                deltaLink: deltaLink,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$DeltaSyncTokensTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $DeltaSyncTokensTable,
      DeltaSyncToken,
      $$DeltaSyncTokensTableFilterComposer,
      $$DeltaSyncTokensTableOrderingComposer,
      $$DeltaSyncTokensTableAnnotationComposer,
      $$DeltaSyncTokensTableCreateCompanionBuilder,
      $$DeltaSyncTokensTableUpdateCompanionBuilder,
      (
        DeltaSyncToken,
        BaseReferences<_$AppDatabase, $DeltaSyncTokensTable, DeltaSyncToken>,
      ),
      DeltaSyncToken,
      PrefetchHooks Function()
    >;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$CachedEmailsTableTableManager get cachedEmails =>
      $$CachedEmailsTableTableManager(_db, _db.cachedEmails);
  $$KnownSendersTableTableManager get knownSenders =>
      $$KnownSendersTableTableManager(_db, _db.knownSenders);
  $$DeltaSyncTokensTableTableManager get deltaSyncTokens =>
      $$DeltaSyncTokensTableTableManager(_db, _db.deltaSyncTokens);
}
