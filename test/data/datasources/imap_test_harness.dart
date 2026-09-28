/// A local IMAP + SMTP server pair for driving [ImapDatasourceImpl] end to
/// end, with nothing in the datasource swapped out.
///
/// The datasource opens real sockets to `127.0.0.1` on the harness's ports,
/// so a test exercises the same code as production: the connection chain,
/// SELECT before FETCH, literal parsing, the SMTP dialogue and the Sent-folder
/// APPEND that follows a send. Both servers keep just enough protocol to
/// satisfy enough_mail and record what the client asked of them; a test
/// seeds mailboxes with raw messages and reads back what was sent and
/// appended.
///
/// Usage:
/// ```dart
/// final harness = await ImapTestHarness.start();
/// addTearDown(harness.close);
/// harness.imap.seed('INBOX', uid: 5, raw: 'Subject: Hi\r\n\r\nbody');
/// await harness.datasource.replyToEmail(messageId: 'INBOX:5', comment: 'x');
/// expect(harness.smtp.sent.single.message.decodeSubject(), 'Re: Hi');
/// ```
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:enough_mail/enough_mail.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:nightmail/data/datasources/remote/imap_datasource_impl.dart';
import 'package:nightmail/infrastructure/accounts/account.dart';
import 'package:nightmail/infrastructure/auth/imap_credential_storage.dart';

const testImapPassword = 'hunter2';

class ImapTestHarness {
  ImapTestHarness._(this.imap, this.smtp, this.account)
    : datasource = ImapDatasourceImpl(
        account: account,
        credentialStorage: _FixedPasswordStorage(testImapPassword),
      );

  final FakeImapServer imap;
  final FakeSmtpServer smtp;
  final ImapAccount account;
  final ImapDatasourceImpl datasource;

  static Future<ImapTestHarness> start({
    String emailAddress = 'me@example.com',
    String displayName = 'Me',
  }) async {
    final imap = await FakeImapServer.start();
    final smtp = await FakeSmtpServer.start();
    final account = ImapAccount(
      id: 'imap-test',
      displayName: displayName,
      emailAddress: emailAddress,
      host: '127.0.0.1',
      port: imap.port,
      useSsl: false,
      smtpHost: '127.0.0.1',
      smtpPort: smtp.port,
      smtpUseSsl: false,
    );
    return ImapTestHarness._(imap, smtp, account);
  }

  Future<void> close() async {
    await imap.close();
    await smtp.close();
  }
}

/// Stands in for the keychain with one password in it.
class _FixedPasswordStorage extends ImapCredentialStorage {
  _FixedPasswordStorage(this._password) : super(const FlutterSecureStorage());

  final String _password;

  @override
  Future<String?> loadPassword(String accountId) async => _password;
}

// -----------------------------------------------------------------------------
// IMAP
// -----------------------------------------------------------------------------

/// One message appended by the client, as the server received it.
class AppendedMessage {
  AppendedMessage({
    required this.mailbox,
    required this.flags,
    required this.raw,
  });

  final String mailbox;
  final List<String> flags;
  final String raw;

  MimeMessage get message => MimeMessage.parseFromText(raw);
}

/// A scripted IMAP4rev1 server that answers LOGIN, LIST, SELECT, STATUS,
/// UID FETCH (BODY.PEEK[] and FLAGS), APPEND, NOOP, IDLE and LOGOUT from an
/// in-memory set of mailboxes. Anything else is acknowledged with `OK` so an
/// unexpected command shows up in [commands] rather than hanging the client.
class FakeImapServer {
  FakeImapServer._(this._server);

  static Future<FakeImapServer> start() async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final fake = FakeImapServer._(server);
    server.listen(fake._accept);
    return fake;
  }

  final ServerSocket _server;
  final List<_ImapSession> _sessions = [];

  int get port => _server.port;

  /// Mailbox path → (uid → raw RFC 822 text). Seeded by [seed]; the server
  /// starts with an empty INBOX and Sent so a send always has somewhere to
  /// file its copy.
  final Map<String, Map<int, String>> mailboxes = {'INBOX': {}, 'Sent': {}};

  /// Special-use attribute per mailbox, as LIST reports it.
  final Map<String, String> mailboxAttributes = {'Sent': r'\Sent'};

  /// Every command line the client sent, in order, tags stripped.
  final List<String> commands = [];

  /// Every APPEND the client completed, in order.
  final List<AppendedMessage> appended = [];

  /// Credentials the client logged in with.
  String? loginUser;
  String? loginPassword;

  /// The password LOGIN must present; anything else gets `NO`.
  String expectedPassword = testImapPassword;

  /// Puts [raw] into [mailbox] under [uid], creating the mailbox if needed.
  void seed(String mailbox, {required int uid, required String raw}) {
    mailboxes.putIfAbsent(mailbox, () => {})[uid] = raw;
  }

  Future<void> close() async {
    for (final s in _sessions) {
      await s.close();
    }
    await _server.close();
  }

  void _accept(Socket socket) {
    _sessions.add(_ImapSession(this, socket));
  }
}

class _ImapSession {
  _ImapSession(this._server, this._socket) {
    _socket.listen(_onData, onError: (_) {}, onDone: () {});
    _write(r'* OK [CAPABILITY IMAP4rev1] fake IMAP ready');
  }

  final FakeImapServer _server;
  final Socket _socket;
  final List<int> _buf = [];

  String? _pendingCommandLine;
  List<int> _literal = [];
  int _literalRemaining = 0;
  bool _idling = false;
  String? _idleTag;
  String _selected = '';

  Future<void> close() async {
    try {
      await _socket.close();
    } catch (_) {}
  }

  void _write(String line) {
    _socket.write('$line\r\n');
  }

  void _onData(Uint8List data) {
    _buf.addAll(data);
    while (true) {
      if (_literalRemaining > 0) {
        final take = min(_literalRemaining, _buf.length);
        _literal.addAll(_buf.sublist(0, take));
        _buf.removeRange(0, take);
        _literalRemaining -= take;
        if (_literalRemaining > 0) return;
        continue;
      }
      final eol = _indexOf(_buf, const [13, 10]);
      if (eol < 0) return;
      final line = utf8.decode(_buf.sublist(0, eol));
      _buf.removeRange(0, eol + 2);

      final literal = RegExp(r'\{(\d+)(\+?)\}$').firstMatch(line);
      if (literal != null && _pendingCommandLine == null) {
        _pendingCommandLine = line;
        _literalRemaining = int.parse(literal.group(1)!);
        _literal = [];
        // A non-synchronising literal (LITERAL+) needs no go-ahead.
        if (literal.group(2)!.isEmpty) _write('+ Ready for literal data');
        continue;
      }
      if (_pendingCommandLine != null) {
        final command = _pendingCommandLine!;
        _pendingCommandLine = null;
        _handle(command, literal: utf8.decode(_literal));
      } else {
        _handle(line);
      }
    }
  }

  void _handle(String line, {String? literal}) {
    if (_idling) {
      if (line.trim().toUpperCase() == 'DONE') {
        _idling = false;
        _write('${_idleTag ?? '*'} OK IDLE terminated');
      }
      return;
    }
    final space = line.indexOf(' ');
    if (space < 0) {
      _write('$line BAD Missing command');
      return;
    }
    final tag = line.substring(0, space);
    final rest = line.substring(space + 1);
    _server.commands.add(rest);
    final args = _tokenize(rest);
    var name = args.isEmpty ? '' : args.first.toUpperCase();
    var argv = args.skip(1).toList();
    if (name == 'UID' && argv.isNotEmpty) {
      name = 'UID ${argv.first.toUpperCase()}';
      argv = argv.skip(1).toList();
    }

    switch (name) {
      case 'CAPABILITY':
        _write('* CAPABILITY IMAP4rev1');
        _write('$tag OK CAPABILITY completed');
      case 'LOGIN':
        _server.loginUser = argv.elementAtOrNull(0);
        _server.loginPassword = argv.elementAtOrNull(1);
        if (_server.loginPassword != _server.expectedPassword) {
          _write('$tag NO [AUTHENTICATIONFAILED] Authentication failed');
        } else {
          _write('$tag OK [CAPABILITY IMAP4rev1] LOGIN completed');
        }
      case 'LIST':
      case 'LSUB':
        for (final entry in _server.mailboxes.entries) {
          final attr = _server.mailboxAttributes[entry.key];
          final attrs = [r'\HasNoChildren', ?attr].join(' ');
          _write('* $name ($attrs) "/" "${entry.key}"');
        }
        _write('$tag OK $name completed');
      case 'SELECT':
      case 'EXAMINE':
        final path = argv.elementAtOrNull(0) ?? '';
        final box = _server.mailboxes[path];
        if (box == null) {
          _write("$tag NO [NONEXISTENT] Mailbox doesn't exist: $path");
          return;
        }
        _selected = path;
        _write('* ${box.length} EXISTS');
        _write('* 0 RECENT');
        _write(r'* FLAGS (\Answered \Flagged \Deleted \Seen \Draft)');
        _write(
          r'* OK [PERMANENTFLAGS (\Answered \Flagged \Deleted \Seen '
          r'\Draft \*)] Flags permitted',
        );
        _write('* OK [UIDVALIDITY 1] UIDs valid');
        _write('* OK [UIDNEXT ${_uidNext(box)}] Predicted next UID');
        _write('$tag OK [READ-WRITE] $name completed');
      case 'STATUS':
        final path = argv.elementAtOrNull(0) ?? '';
        final box = _server.mailboxes[path];
        if (box == null) {
          _write("$tag NO [NONEXISTENT] Mailbox doesn't exist: $path");
          return;
        }
        _write(
          '* STATUS "$path" (MESSAGES ${box.length} UNSEEN 0 '
          'UIDNEXT ${_uidNext(box)} UIDVALIDITY 1)',
        );
        _write('$tag OK STATUS completed');
      case 'UID FETCH':
        _uidFetch(tag, argv);
      case 'APPEND':
        final path = argv.elementAtOrNull(0) ?? '';
        final flags = argv
            .skip(1)
            .where((a) => a.startsWith('('))
            .expand((a) => a.substring(1, a.length - 1).split(' '))
            .where((f) => f.isNotEmpty)
            .toList();
        final box = _server.mailboxes[path];
        if (box == null) {
          _write("$tag NO [TRYCREATE] Mailbox doesn't exist: $path");
          return;
        }
        final uid = _uidNext(box);
        box[uid] = literal ?? '';
        _server.appended.add(
          AppendedMessage(mailbox: path, flags: flags, raw: literal ?? ''),
        );
        _write('$tag OK [APPENDUID 1 $uid] APPEND completed');
      case 'IDLE':
        _idling = true;
        _idleTag = tag;
        _write('+ idling');
      case 'LOGOUT':
        _write('* BYE Logging out');
        _write('$tag OK LOGOUT completed');
        close();
      default:
        _write('$tag OK $name completed');
    }
  }

  void _uidFetch(String tag, List<String> argv) {
    final box = _server.mailboxes[_selected] ?? {};
    final uids = _parseSequence(argv.elementAtOrNull(0) ?? '', box);
    final items = argv.skip(1).join(' ').toUpperCase();
    final wantsBody = items.contains('BODY.PEEK[]') || items.contains('BODY[]');
    final sorted = box.keys.toList()..sort();
    for (final uid in uids) {
      final raw = box[uid];
      if (raw == null) continue;
      final seq = sorted.indexOf(uid) + 1;
      if (wantsBody) {
        final bytes = utf8.encode(raw);
        _socket.write(
          '* $seq FETCH (UID $uid FLAGS () BODY[] {${bytes.length}}\r\n',
        );
        _socket.add(bytes);
        _socket.write(')\r\n');
      } else {
        _write('* $seq FETCH (UID $uid FLAGS ())');
      }
    }
    _write('$tag OK UID FETCH completed');
  }

  static int _uidNext(Map<int, String> box) =>
      box.keys.fold(0, (m, u) => u > m ? u : m) + 1;

  static List<int> _parseSequence(String set, Map<int, String> box) {
    final out = <int>[];
    final sorted = box.keys.toList()..sort();
    for (final part in set.split(',')) {
      final range = part.split(':');
      if (range.length == 2) {
        final last = sorted.lastOrNull ?? 0;
        final from = range[0] == '*' ? last : int.parse(range[0]);
        final to = range[1] == '*' ? last : int.parse(range[1]);
        for (final u in sorted) {
          if (u >= min(from, to) && u <= max(from, to)) out.add(u);
        }
      } else {
        final uid = int.tryParse(part);
        if (uid != null) out.add(uid);
      }
    }
    return out;
  }

  /// Splits an IMAP command line into atoms, quoted strings (unquoted) and
  /// parenthesised lists (kept whole, brackets included).
  static List<String> _tokenize(String line) {
    final out = <String>[];
    var i = 0;
    while (i < line.length) {
      final c = line[i];
      if (c == ' ') {
        i++;
      } else if (c == '"') {
        final end = line.indexOf('"', i + 1);
        out.add(line.substring(i + 1, end < 0 ? line.length : end));
        i = end < 0 ? line.length : end + 1;
      } else if (c == '(') {
        var depth = 0;
        var j = i;
        for (; j < line.length; j++) {
          if (line[j] == '(') depth++;
          if (line[j] == ')') depth--;
          if (depth == 0) break;
        }
        out.add(line.substring(i, min(j + 1, line.length)));
        i = j + 1;
      } else {
        var j = i;
        while (j < line.length && line[j] != ' ') {
          j++;
        }
        out.add(line.substring(i, j));
        i = j;
      }
    }
    return out;
  }
}

// -----------------------------------------------------------------------------
// SMTP
// -----------------------------------------------------------------------------

/// One message the client delivered over SMTP.
class SentMail {
  SentMail({required this.from, required this.recipients, required this.raw});

  final String from;
  final List<String> recipients;
  final String raw;

  MimeMessage get message => MimeMessage.parseFromText(raw);
}

/// A scripted ESMTP server: EHLO, AUTH PLAIN, MAIL/RCPT/DATA, RSET, NOOP and
/// QUIT. It advertises no STARTTLS and no CHUNKING, so the client speaks
/// plain DATA over the plain socket.
class FakeSmtpServer {
  FakeSmtpServer._(this._server);

  static Future<FakeSmtpServer> start() async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final fake = FakeSmtpServer._(server);
    server.listen(fake._accept);
    return fake;
  }

  final ServerSocket _server;
  final List<_SmtpSession> _sessions = [];

  int get port => _server.port;

  /// Every message delivered, in order.
  final List<SentMail> sent = [];

  /// Every command line the client sent (DATA bodies excluded), in order.
  final List<String> commands = [];

  /// Credentials the client authenticated with.
  String? authUser;
  String? authPassword;

  /// The password AUTH must present; anything else gets `535`.
  String expectedPassword = testImapPassword;

  Future<void> close() async {
    for (final s in _sessions) {
      await s.close();
    }
    await _server.close();
  }

  void _accept(Socket socket) {
    _sessions.add(_SmtpSession(this, socket));
  }
}

class _SmtpSession {
  _SmtpSession(this._server, this._socket) {
    _socket.listen(_onData, onError: (_) {}, onDone: () {});
    _write('220 fake ESMTP ready');
  }

  final FakeSmtpServer _server;
  final Socket _socket;
  final List<int> _buf = [];

  bool _inData = false;
  String _from = '';
  final List<String> _recipients = [];

  /// CR LF '.' CR LF — the end-of-DATA marker.
  static const _endOfData = [13, 10, 46, 13, 10];

  Future<void> close() async {
    try {
      await _socket.close();
    } catch (_) {}
  }

  void _write(String line) {
    _socket.write('$line\r\n');
  }

  void _onData(Uint8List data) {
    _buf.addAll(data);
    while (true) {
      if (_inData) {
        final end = _indexOf(_buf, _endOfData);
        if (end < 0) return;
        final raw = utf8
            .decode(_buf.sublist(0, end))
            .replaceAll('\r\n..', '\r\n.');
        _buf.removeRange(0, end + _endOfData.length);
        _inData = false;
        _server.sent.add(
          SentMail(
            from: _from,
            recipients: List.unmodifiable(_recipients),
            raw: raw,
          ),
        );
        _from = '';
        _recipients.clear();
        _write('250 2.0.0 Ok: queued');
        continue;
      }
      final eol = _indexOf(_buf, const [13, 10]);
      if (eol < 0) return;
      final line = utf8.decode(_buf.sublist(0, eol));
      _buf.removeRange(0, eol + 2);
      _handle(line);
    }
  }

  void _handle(String line) {
    _server.commands.add(line);
    final upper = line.toUpperCase();
    if (upper.startsWith('EHLO') || upper.startsWith('HELO')) {
      _write('250-fake');
      _write('250-AUTH PLAIN LOGIN');
      _write('250 8BITMIME');
    } else if (upper.startsWith('AUTH PLAIN')) {
      final encoded = line.substring('AUTH PLAIN'.length).trim();
      // authzid NUL authcid NUL password
      final parts = utf8
          .decode(base64.decode(encoded))
          .split(String.fromCharCode(0));
      _server.authUser = parts.elementAtOrNull(1);
      _server.authPassword = parts.elementAtOrNull(2);
      if (_server.authPassword != _server.expectedPassword) {
        _write('535 5.7.8 Authentication credentials invalid');
      } else {
        _write('235 2.7.0 Authentication successful');
      }
    } else if (upper.startsWith('MAIL FROM:')) {
      _from = _angleAddress(line.substring('MAIL FROM:'.length));
      _write('250 2.1.0 Ok');
    } else if (upper.startsWith('RCPT TO:')) {
      _recipients.add(_angleAddress(line.substring('RCPT TO:'.length)));
      _write('250 2.1.5 Ok');
    } else if (upper == 'DATA') {
      _inData = true;
      _write('354 End data with <CR><LF>.<CR><LF>');
    } else if (upper == 'RSET') {
      _from = '';
      _recipients.clear();
      _write('250 2.0.0 Ok');
    } else if (upper == 'QUIT') {
      _write('221 2.0.0 Bye');
      close();
    } else {
      _write('250 2.0.0 Ok');
    }
  }

  static String _angleAddress(String s) {
    final m = RegExp(r'<([^>]*)>').firstMatch(s);
    return m?.group(1) ?? s.trim();
  }
}

/// Index of [needle] in [bytes], or -1.
int _indexOf(List<int> bytes, List<int> needle) {
  outer:
  for (var i = 0; i + needle.length <= bytes.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (bytes[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  return -1;
}
