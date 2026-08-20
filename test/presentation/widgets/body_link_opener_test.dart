import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/domain/entities/cloud_document.dart';
import 'package:nightmail/presentation/widgets/body_link_opener.dart';
import 'package:nightmail/presentation/widgets/cloud_document_preview_host.dart';

/// Where a clicked body link ends up.
///
/// The one rule worth pinning: a cloud document link is only ever *offered* to
/// the surface that can preview it, and every path that offer does not take
/// ends in the browser — the behaviour the link had before any of this existed.
void main() {
  const launcherChannel = MethodChannel('plugins.flutter.io/url_launcher');
  const driveUrl = 'https://drive.google.com/file/d/1AbCdEfGhIjKlMn/view';
  const sharePointUrl =
      'https://contoso.sharepoint.com/:w:/g/personal/ann_contoso_com/Ee7abcdefgh';
  const ordinaryUrl = 'https://example.com/news';

  // url_launcher's implementation is a method channel with no plugin behind it
  // in a widget test, so launches are recorded here instead.
  final launched = <String>[];
  final offered = <CloudDocumentLink>[];

  void mock(MethodChannel channel, Future<Object?>? Function(MethodCall)? h) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, h);
  }

  setUp(() {
    launched.clear();
    offered.clear();
    mock(launcherChannel, (call) async {
      if (call.method == 'launch') {
        launched.add((call.arguments as Map)['url'] as String);
      }
      return true;
    });
  });

  tearDown(() => mock(launcherChannel, null));

  /// Pumps a button that opens [url], with or without a preview host above it.
  Future<void> pumpLink(
    WidgetTester tester,
    String url, {
    Future<bool> Function(CloudDocumentLink)? host,
  }) async {
    Widget button = Builder(
      builder: (context) => TextButton(
        onPressed: () => openBodyLink(context, url),
        child: const Text('link'),
      ),
    );
    if (host != null) {
      button = CloudDocumentPreviewHost(
        onPreview: (link) {
          offered.add(link);
          return host(link);
        },
        child: button,
      );
    }
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: button)));
    await tester.tap(find.text('link'));
    await tester.pumpAndSettle();
  }

  testWidgets('a Drive link the host previews never reaches the browser',
      (tester) async {
    await pumpLink(tester, driveUrl, host: (_) async => true);

    expect(offered.single.provider, CloudDriveProvider.google);
    expect(offered.single.fileId, '1AbCdEfGhIjKlMn');
    expect(launched, isEmpty);
  });

  testWidgets('a SharePoint link is offered whole, for Graph to resolve',
      (tester) async {
    await pumpLink(tester, sharePointUrl, host: (_) async => true);

    expect(offered.single.provider, CloudDriveProvider.microsoft);
    expect(offered.single.url, sharePointUrl);
    expect(launched, isEmpty);
  });

  testWidgets('a host that declines hands the link to the browser',
      (tester) async {
    // What the reader sees when no account can reach the file, or they refuse
    // the permission: exactly what the link did before.
    await pumpLink(tester, driveUrl, host: (_) async => false);

    expect(offered, hasLength(1));
    expect(launched, [driveUrl]);
  });

  testWidgets('with no host in scope the link opens in the browser',
      (tester) async {
    // The standalone email window has nowhere to draw a preview.
    await pumpLink(tester, driveUrl);

    expect(offered, isEmpty);
    expect(launched, [driveUrl]);
  });

  testWidgets('an ordinary link is never offered to the host', (tester) async {
    await pumpLink(tester, ordinaryUrl, host: (_) async => true);

    expect(offered, isEmpty);
    expect(launched, [ordinaryUrl]);
  });
}
