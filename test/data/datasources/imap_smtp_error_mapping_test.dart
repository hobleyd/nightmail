import 'dart:io';

import 'package:enough_mail/enough_mail.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/core/error/exceptions.dart';
import 'package:nightmail/data/datasources/remote/imap_datasource_impl.dart';

/// The exception Dart raises when TLS is spoken at a server that answers in
/// plaintext — the whole reason this mapping exists. `Handshake error in
/// client` on its own tells the user nothing about which knob to turn.
HandshakeException _handshakeError([String message = 'Handshake error in client']) =>
    HandshakeException(message,
        const OSError('WRONG_VERSION_NUMBER(tls_record.cc:242)', 0));

/// Builds an [SmtpException] the way [SmtpClient] does: from the server's
/// response lines. A null client is fine — the mapping only reads `response`.
SmtpException _smtpError(String responseLine) =>
    SmtpException(_NullSmtpClient(), SmtpResponse([responseLine]));

class _NullSmtpClient extends SmtpClient {
  _NullSmtpClient() : super('test');
}

void main() {
  const server = 'mail.example.com:587';

  group('describeSmtpConnectFailure', () {
    test('maps a TLS handshake failure to a ServerException that names the '
        'host and keeps the raw error', () {
      final result = ImapDatasourceImpl.describeSmtpConnectFailure(
        _handshakeError(),
        server,
        true,
      );

      expect(result, isA<ServerException>());
      final message = (result as ServerException).message;
      expect(message, contains(server));
      expect(message, contains('Handshake error in client'));
    });

    test('an unreachable host becomes a NetworkException carrying the OS '
        'error', () {
      final result = ImapDatasourceImpl.describeSmtpConnectFailure(
        const SocketException(
          'Connection refused',
          osError: OSError('Connection refused', 61),
        ),
        server,
        false,
      );

      expect(result, isA<NetworkException>());
      expect((result as NetworkException).message,
          allOf(contains(server), contains('Connection refused')));
    });

    test('a rejected AUTH becomes an AuthException so the account is prompted '
        'to re-authenticate', () {
      for (final code in [530, 534, 535]) {
        final result = ImapDatasourceImpl.describeSmtpConnectFailure(
          _smtpError('$code Authentication credentials invalid'),
          server,
          false,
        );

        expect(result, isA<AuthException>(), reason: 'code $code');
        expect((result as AuthException).message,
            contains('Authentication credentials invalid'));
      }
    });

    test('any other SMTP refusal stays a ServerException and keeps its code',
        () {
      final result = ImapDatasourceImpl.describeSmtpConnectFailure(
        _smtpError('554 Relay access denied'),
        server,
        false,
      );

      expect(result, isA<ServerException>());
      final failure = result as ServerException;
      expect(failure.statusCode, 554);
      expect(failure.message, contains('Relay access denied'));
    });

    test('an unrecognised error is passed through untouched, so nothing is '
        'swallowed or relabelled', () {
      final original = StateError('something else entirely');

      expect(
        ImapDatasourceImpl.describeSmtpConnectFailure(original, server, false),
        same(original),
      );
    });
  });

  group('describeSmtpTlsFailure', () {
    test('with SSL on, points at the implicit-TLS/STARTTLS port mismatch — the '
        'usual cause of a bare handshake error', () {
      final message = ImapDatasourceImpl.describeSmtpTlsFailure(
        _handshakeError(),
        server,
        true,
      );

      expect(message, contains('Use SSL'));
      expect(message, contains('587'));
      expect(message, contains('465'));
    });

    test('a certificate problem is reported as such rather than as a port '
        'mismatch', () {
      final message = ImapDatasourceImpl.describeSmtpTlsFailure(
        _handshakeError(
          'Handshake error in client (CERTIFICATE_VERIFY_FAILED: '
          'self signed certificate)',
        ),
        server,
        true,
      );

      expect(message, contains('certificate'));
      expect(message, isNot(contains('Use SSL')));
    });

    test('with SSL off, the failure is attributed to the STARTTLS upgrade', () {
      final message = ImapDatasourceImpl.describeSmtpTlsFailure(
        _handshakeError(),
        server,
        false,
      );

      expect(message, contains('STARTTLS'));
    });

    test('always keeps the raw error text, since for anything unrecognised it '
        'is the only diagnostic there is', () {
      final error = _handshakeError('totally novel tls failure');

      for (final useSsl in [true, false]) {
        expect(
          ImapDatasourceImpl.describeSmtpTlsFailure(error, server, useSsl),
          contains('totally novel tls failure'),
        );
      }
    });
  });
}
