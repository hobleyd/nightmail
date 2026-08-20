import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/data/datasources/remote/graph_drive_datasource_impl.dart';

/// Graph addresses a sharing link as `u!` + unpadded base64url. Getting the
/// padding or the alphabet wrong is a 400 that reads exactly like "that kind of
/// link is not supported", so the encoding is pinned rather than trusted.
void main() {
  group('encodeSharingUrl', () {
    test('matches the encoding Microsoft documents', () {
      // Microsoft's own worked example.
      expect(
        GraphDriveDatasourceImpl.encodeSharingUrl(
            'https://onedrive.live.com/redir?resid=1231244193912!12&authkey=!AEQ0plfsknjfsjkef'),
        'u!aHR0cHM6Ly9vbmVkcml2ZS5saXZlLmNvbS9yZWRpcj9yZXNpZD0xMjMxMjQ0MTkzOTEyITEyJmF1dGhrZXk9IUFFUTBwbGZza25qZnNqa2Vm',
      );
    });

    test('strips padding and uses the URL-safe alphabet', () {
      // This one's standard base64 ends in `=` and contains a `/`.
      expect(
        GraphDriveDatasourceImpl.encodeSharingUrl(
            'https://contoso.sharepoint.com/:w:/g/personal/ann_contoso_com/Ee7abc?e=4TzQ1k'),
        'u!aHR0cHM6Ly9jb250b3NvLnNoYXJlcG9pbnQuY29tLzp3Oi9nL3BlcnNvbmFsL2Fubl9jb250b3NvX2NvbS9FZTdhYmM_ZT00VHpRMWs',
      );
    });

    test('never emits a character that would need escaping in a path', () {
      const urls = [
        'https://contoso.sharepoint.com/sites/Finance/Shared Documents/Q3 (final).xlsx',
        'https://contoso-my.sharepoint.com/:p:/g/personal/a_b_c/Ef?e=1+2/3',
        'https://contoso.sharepoint.com/sites/Ünïcødé/Doc.docx',
      ];
      for (final url in urls) {
        final id = GraphDriveDatasourceImpl.encodeSharingUrl(url);
        expect(id, startsWith('u!'), reason: url);
        expect(id.substring(2), isNot(contains('=')), reason: url);
        expect(id.substring(2), isNot(contains('+')), reason: url);
        expect(id.substring(2), isNot(contains('/')), reason: url);
      }
    });

    test('round-trips back to the original URL', () {
      const url =
          'https://contoso.sharepoint.com/:x:/r/sites/Finance/Shared%20Documents/Budget.xlsx?d=w1234&csf=1';
      final id = GraphDriveDatasourceImpl.encodeSharingUrl(url).substring(2);
      final padded = id.padRight((id.length + 3) & ~3, '=');
      expect(utf8.decode(base64Url.decode(padded)), url);
    });
  });
}
