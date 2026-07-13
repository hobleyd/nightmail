import '../../infrastructure/accounts/account.dart';

/// Resolves `{{merge_field}}` tags and `IFEXISTS(cond, then, else)` calls in a
/// signature template, as produced by common signature-generator exports
/// (e.g. WiseStamp/HubSpot-style templates).
class SignatureMergeEngine {
  SignatureMergeEngine._();

  static String merge(String template, Account account) {
    if (template.isEmpty) return '';
    return _evalIfExists(_substituteFields(template, _fieldsFor(account)));
  }

  static Map<String, String> _fieldsFor(Account account) => {
        'first_name': account.firstName,
        'last_name': account.lastName,
        'job_title': account.jobTitle,
        'phone': account.phone,
        'mobile': account.mobile,
        'email': account.emailAddress,
        'address': account.address,
      };

  static final _fieldPattern = RegExp(r'\{\{(\w+)\}\}');

  static String _substituteFields(String template, Map<String, String> fields) {
    return template.replaceAllMapped(
        _fieldPattern, (m) => fields[m.group(1)] ?? '');
  }

  /// Evaluates `IFEXISTS(cond, then, else)`: emits `then` if `cond` (already
  /// merge-field-substituted) is non-empty, otherwise `else`. Runs after
  /// field substitution, so `cond` is the literal resolved value/text — this
  /// also makes concatenations like `IFEXISTS({{phone}}{{mobile}}, | , )`
  /// (a conditional separator) work with plain non-empty checks.
  static String _evalIfExists(String input) {
    final buffer = StringBuffer();
    var i = 0;
    while (true) {
      final idx = input.indexOf('IFEXISTS(', i);
      if (idx == -1) {
        buffer.write(input.substring(i));
        break;
      }
      buffer.write(input.substring(i, idx));

      final parenStart = idx + 'IFEXISTS'.length;
      var depth = 0;
      var lastSplit = parenStart + 1;
      final parts = <String>[];
      var j = parenStart;
      for (; j < input.length; j++) {
        final ch = input[j];
        if (ch == '(') {
          depth++;
        } else if (ch == ')') {
          depth--;
          if (depth == 0) break;
        } else if (ch == ',' && depth == 1) {
          parts.add(input.substring(lastSplit, j));
          lastSplit = j + 1;
        }
      }
      if (j >= input.length) {
        // Unbalanced parens — bail out and emit the rest verbatim.
        buffer.write(input.substring(idx));
        break;
      }
      parts.add(input.substring(lastSplit, j));

      final cond = parts.isNotEmpty ? parts[0].trim() : '';
      final thenVal = parts.length > 1 ? parts[1] : '';
      final elseVal = parts.length > 2 ? parts[2] : '';
      buffer.write(cond.isNotEmpty ? thenVal : elseVal);
      i = j + 1;
    }
    return buffer.toString();
  }
}
