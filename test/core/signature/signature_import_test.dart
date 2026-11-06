import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/core/signature/signature_import.dart';

void main() {
  group('SignatureImport.fromBytes', () {
    test('keeps only the body and leaves merge tags unresolved', () {
      const file = '<!DOCTYPE html><html><head><title>Sig</title>'
          '<style>p{color:red}</style></head>'
          '<body style="margin:0"><p>{{first_name}} {{last_name}}</p>'
          'IFEXISTS({{mobile}}, M: {{mobile}}, )</body></html>';
      expect(
        SignatureImport.fromBytes(utf8.encode(file)),
        '<p>{{first_name}} {{last_name}}</p>IFEXISTS({{mobile}}, M: {{mobile}}, )',
      );
    });

    test('takes a fragment without a body as it is', () {
      expect(
        SignatureImport.fromBytes(utf8.encode('  <b>{{job_title}}</b>\n')),
        '<b>{{job_title}}</b>',
      );
    });

    test('decodes UTF-8 with a BOM', () {
      expect(
        SignatureImport.fromBytes([0xEF, 0xBB, 0xBF, ...utf8.encode('Zoë')]),
        'Zoë',
      );
    });

    test('decodes UTF-16LE with a BOM', () {
      final units = 'Zoë – CEO'.codeUnits;
      final bytes = [0xFF, 0xFE];
      for (final u in units) {
        bytes..add(u & 0xFF)..add(u >> 8);
      }
      expect(SignatureImport.fromBytes(bytes), 'Zoë – CEO');
    });

    test('falls back to Windows-1252 when the file is not UTF-8', () {
      // "Zoë – ‘CEO’" as Outlook writes it.
      final bytes = [
        0x5A, 0x6F, 0xEB, 0x20, 0x96, 0x20, 0x91, 0x43, 0x45, 0x4F, 0x92,
      ];
      expect(SignatureImport.fromBytes(bytes), 'Zoë – ‘CEO’');
    });
  });
}
