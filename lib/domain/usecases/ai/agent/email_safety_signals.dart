import 'dart:convert';
import 'dart:typed_data';

import '../../../entities/email.dart';
import '../../../entities/email_attachment.dart';
import '../../check_sender_anomaly.dart';

/// The evidence `check_email_safety` hands the folder agent so it can judge
/// whether a message is phishing, spoofed or carries something dangerous,
/// rather than guessing from the subject and body text.
///
/// Pure functions over what the app already has: the message's raw source
/// (only its header block is read), the parsed [Email] (links in the body,
/// attachments) and the lookalike-sender result. Every value is evidence for
/// the model to weigh, never a verdict — a newsletter fails half of these.
///
/// Links are reported as hosts only, never full URLs: a query string can
/// carry a sign-in or unsubscribe token, and this output goes to a cloud
/// provider whether or not the user opted in to sending bodies.
Map<String, dynamic> emailSafetySignals({
  required Email email,
  Uint8List? rawSource,
  SenderAnomalyResult? senderAnomaly,
}) {
  final headers = rawSource == null ? null : parseHeaderBlock(rawSource);
  final fromAddress = email.from.address.toLowerCase();
  final fromDomain = _domainOf(fromAddress);

  final signals = <String, dynamic>{
    'id': email.id,
    'from': email.from.name == null || email.from.name!.isEmpty
        ? fromAddress
        : '${email.from.name} <$fromAddress>',
    'subject': email.subject,
  };

  if (headers == null) {
    signals['authentication'] = 'unavailable — the raw message could not be '
        'fetched, so SPF/DKIM/DMARC and Reply-To are unknown';
  } else {
    signals['authentication'] = _authentication(headers);
    final replyTo = _firstAddress(_header(headers, 'reply-to'));
    if (replyTo != null && replyTo != fromAddress) {
      signals['replyTo'] = {
        'address': replyTo,
        'differentDomainFromSender':
            _registrableDomain(_domainOf(replyTo)) !=
                _registrableDomain(fromDomain),
      };
    }
    final returnPath = _firstAddress(_header(headers, 'return-path'));
    if (returnPath != null) {
      signals['returnPath'] = {
        'address': returnPath,
        'differentDomainFromSender':
            _registrableDomain(_domainOf(returnPath)) !=
                _registrableDomain(fromDomain),
      };
    }
  }

  final nameAddress = _firstAddress(email.from.name ?? '');
  if (nameAddress != null && nameAddress != fromAddress) {
    signals['displayNameShowsOtherAddress'] = nameAddress;
  }

  if (senderAnomaly != null) {
    signals['lookalikeOfKnownSender'] = {
      'note': 'The display name closely matches people the user has had mail '
          'from before, but this address is not one of theirs.',
      'knownAddresses': [
        for (final m in senderAnomaly.matches) '${m.name} <${m.address}>',
      ],
    };
  }

  signals['links'] = _links(email);
  signals['attachments'] = [
    for (final a in email.attachments) _attachment(a),
  ];
  return signals;
}

/// The header block of a raw RFC 822 message as (lower-cased name, value)
/// pairs in source order, continuation lines unfolded. Stops at the first
/// blank line, so the body and its attachments are never decoded.
List<(String, String)> parseHeaderBlock(Uint8List raw) {
  var end = raw.length;
  for (var i = 0; i + 1 < raw.length; i++) {
    if (raw[i] != 0x0A) continue;
    final next = raw[i + 1];
    if (next == 0x0A ||
        (next == 0x0D && i + 2 < raw.length && raw[i + 2] == 0x0A)) {
      end = i;
      break;
    }
  }
  final text = latin1.decode(Uint8List.sublistView(raw, 0, end));
  final headers = <(String, String)>[];
  for (final line in text.split(RegExp(r'\r?\n'))) {
    if (line.isEmpty) continue;
    if ((line.startsWith(' ') || line.startsWith('\t')) &&
        headers.isNotEmpty) {
      final (name, value) = headers.removeLast();
      headers.add((name, '$value ${line.trim()}'));
      continue;
    }
    final colon = line.indexOf(':');
    if (colon <= 0) continue;
    headers.add((
      line.substring(0, colon).trim().toLowerCase(),
      line.substring(colon + 1).trim(),
    ));
  }
  return headers;
}

/// SPF / DKIM / DMARC as the receiving server recorded them. The topmost
/// `Authentication-Results` is the one the user's own provider added; lower
/// ones were written by relays and can be forged by the sender.
Map<String, dynamic> _authentication(List<(String, String)> headers) {
  final results = _header(headers, 'authentication-results');
  final receivedSpf = _header(headers, 'received-spf');
  String? verdict(String method) {
    final match = RegExp('\\b$method=([a-z]+)', caseSensitive: false)
        .firstMatch(results ?? '');
    return match?.group(1)?.toLowerCase();
  }

  final spf = verdict('spf') ??
      RegExp(r'^\s*([a-z]+)', caseSensitive: false)
          .firstMatch(receivedSpf ?? '')
          ?.group(1)
          ?.toLowerCase();
  final auth = <String, dynamic>{
    'spf': spf ?? 'not recorded',
    'dkim': verdict('dkim') ?? 'not recorded',
    'dmarc': verdict('dmarc') ?? 'not recorded',
  };
  if (results == null && receivedSpf == null) {
    auth['note'] = 'No Authentication-Results header — some providers (IMAP '
        'servers especially) do not record one, so absence is not itself '
        'suspicious.';
  }
  return auth;
}

/// Most links an email reports individually; the rest are only counted.
const _maxReportedHosts = 15;

Map<String, dynamic> _links(Email email) {
  final mismatched = <Map<String, String>>[];
  final hosts = <String>{};
  final ipHosts = <String>{};
  final punycodeHosts = <String>{};
  final insecure = <String>{};

  void note(Uri uri) {
    final host = uri.host.toLowerCase();
    if (host.isEmpty) return;
    hosts.add(host);
    if (RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(host) ||
        host.startsWith('[')) {
      ipHosts.add(host);
    }
    if (host.split('.').any((l) => l.startsWith('xn--'))) {
      punycodeHosts.add(host);
    }
    if (uri.scheme == 'http') insecure.add(host);
  }

  if (email.bodyType == EmailBodyType.html) {
    final anchor = RegExp(
      r'''<a\b[^>]*?\bhref\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))[^>]*>(.*?)</a\s*>''',
      caseSensitive: false,
      dotAll: true,
    );
    for (final m in anchor.allMatches(email.body)) {
      final href = _decodeEntities(m.group(1) ?? m.group(2) ?? m.group(3) ?? '');
      final uri = Uri.tryParse(href.trim());
      if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
        continue;
      }
      note(uri);
      final text = _decodeEntities(
              (m.group(4) ?? '').replaceAll(RegExp(r'<[^>]*>'), ''))
          .trim();
      final shownHost = _hostShownIn(text);
      if (shownHost != null &&
          _registrableDomain(shownHost) !=
              _registrableDomain(uri.host.toLowerCase())) {
        mismatched.add({'shows': shownHost, 'goesTo': uri.host.toLowerCase()});
      }
    }
  } else {
    for (final m in RegExp(r'https?://[^\s<>"]+').allMatches(email.body)) {
      final uri = Uri.tryParse(m.group(0)!);
      if (uri != null) note(uri);
    }
  }

  final fromDomain = _registrableDomain(_domainOf(email.from.address));
  final otherDomains = {
    for (final h in hosts)
      if (_registrableDomain(h) != fromDomain) _registrableDomain(h),
  };
  return {
    'count': hosts.length,
    'hosts': hosts.take(_maxReportedHosts).toList(),
    'domainsOtherThanSender': otherDomains.take(_maxReportedHosts).toList(),
    if (mismatched.isNotEmpty)
      'textShowsDifferentDomain': mismatched.take(_maxReportedHosts).toList(),
    if (ipHosts.isNotEmpty) 'rawIpHosts': ipHosts.toList(),
    if (punycodeHosts.isNotEmpty) 'punycodeHosts': punycodeHosts.toList(),
    if (insecure.isNotEmpty) 'plainHttpHosts': insecure.toList(),
  };
}

/// File types that run code when opened, or hide something that does.
const _riskyExtensions = {
  'exe', 'scr', 'com', 'pif', 'bat', 'cmd', 'msi', 'msp', 'js', 'jse',
  'vbs', 'vbe', 'wsf', 'wsh', 'hta', 'ps1', 'jar', 'lnk', 'iso', 'img',
  'vhd', 'vhdx', 'one', 'html', 'htm', 'svg', 'docm', 'xlsm', 'pptm',
  'dotm', 'xlam', 'reg', 'cpl', 'app', 'dmg', 'pkg', 'command',
};

Map<String, dynamic> _attachment(EmailAttachment a) {
  final parts = a.name.toLowerCase().split('.');
  final ext = parts.length > 1 ? parts.last : '';
  return {
    'name': a.name,
    'contentType': a.contentType,
    'size': a.size,
    if (_riskyExtensions.contains(ext)) 'riskyType': true,
    if (parts.length > 2 && _riskyExtensions.contains(ext)) 'doubleExtension': true,
  };
}

/// The host a link's visible text claims to go to, when the text reads like
/// an address (`www.bank.com`, `https://bank.com/login`) rather than words.
String? _hostShownIn(String text) {
  final m = RegExp(
    r'^(?:https?://)?((?:[a-z0-9-]+\.)+[a-z]{2,})(?:[/:?#]\S*)?$',
    caseSensitive: false,
  ).firstMatch(text);
  return m?.group(1)?.toLowerCase();
}

String? _header(List<(String, String)> headers, String name) {
  for (final (n, v) in headers) {
    if (n == name) return v;
  }
  return null;
}

String? _firstAddress(String? value) {
  if (value == null) return null;
  final m = RegExp(r'[\w.+\-]+@[\w\-]+(\.[\w\-]+)+').firstMatch(value);
  return m?.group(0)?.toLowerCase();
}

String _domainOf(String address) {
  final at = address.lastIndexOf('@');
  return at < 0 ? '' : address.substring(at + 1).toLowerCase();
}

/// Second-level labels under which a country code registers names
/// (`example.com.au`, `example.co.uk`).
const _secondLevel = {'co', 'com', 'net', 'org', 'gov', 'edu', 'ac', 'id'};

/// The name an organisation registers — `mail.example.com.au` →
/// `example.com.au` — so a sender's own subdomains don't read as mismatches.
/// An approximation of the public-suffix list, good enough for evidence.
String _registrableDomain(String host) {
  final labels = host.split('.').where((l) => l.isNotEmpty).toList();
  if (labels.length <= 2) return labels.join('.');
  final take = labels.last.length == 2 &&
          _secondLevel.contains(labels[labels.length - 2])
      ? 3
      : 2;
  return labels.sublist(labels.length - take).join('.');
}

String _decodeEntities(String s) => s
    .replaceAll('&amp;', '&')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&nbsp;', ' ');
