import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Every Graph and Microsoft sign-in URL goes through the account's
/// `GraphEndpoints`. One hardcoded `https://graph.microsoft.com/...` left in a
/// datasource sends a NightMail Server account's bearer token to Microsoft —
/// which fails quietly as a 401, so nothing visible says it happened.
///
/// The only places Microsoft's hosts may be spelled out are the Microsoft
/// default itself (`graph_endpoints.dart`) and the Graph permission names in
/// `microsoft_auth_service.dart` — scope identifiers that are never requested
/// as URLs (`https://graph.microsoft.com/Mail.Read`).
void main() {
  test('no Microsoft Graph or login URL outside the default endpoint config',
      () {
    final host = RegExp(r'graph\.microsoft\.com|login\.microsoftonline\.com');
    final scope = RegExp(r"'https://graph\.microsoft\.com/[A-Z][A-Za-z.]*'");
    final offenders = <String>[];

    final files = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'));
    for (final file in files) {
      final path = file.path.replaceAll(r'\', '/');
      if (path.endsWith('lib/domain/entities/graph_endpoints.dart')) continue;
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        if (!host.hasMatch(line)) continue;
        // A line whose every mention is a permission name is fine; one that
        // also carries a URL is not.
        final onlyScopeNames =
            path.endsWith('lib/infrastructure/auth/microsoft_auth_service.dart') &&
                !host.hasMatch(line.replaceAll(scope, ''));
        if (onlyScopeNames) continue;
        offenders.add('$path:${i + 1}: ${line.trim()}');
      }
    }

    expect(offenders, isEmpty,
        reason: 'Route these through GraphEndpoints (the account\'s '
            'graphBaseUrl / graphBetaBaseUrl / authorization and token '
            'endpoints):\n${offenders.join('\n')}');
  });
}
