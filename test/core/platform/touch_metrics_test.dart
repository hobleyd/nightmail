import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/core/platform/touch_metrics.dart';

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  group('touch metrics — desktop', () {
    setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.windows);

    test('is not a touch platform', () {
      expect(isTouchPlatform, isFalse);
    });

    test('leaves icons, targets and row heights exactly as asked', () {
      expect(touchIcon(16), 16);
      expect(touchTarget(28), 28);
      expect(touchRowHeight(28), 28);
    });
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    group('touch metrics — ${platform.name}', () {
      setUp(() => debugDefaultTargetPlatformOverride = platform);

      test('is a touch platform', () {
        expect(isTouchPlatform, isTrue);
      });

      test('doubles every icon', () {
        expect(touchIcon(12), 24);
        expect(touchIcon(16), 32);
        expect(touchIcon(20), 40);
      });

      test('flattens tap targets to the platform minimum, not double', () {
        // Doubling the compact desktop boxes would need 384 px for the list
        // header's six buttons and overflow a narrow phone.
        expect(touchTarget(24), kTouchTargetSize);
        expect(touchTarget(32), kTouchTargetSize);
      });

      test('grows a row only when it is shorter than a tap target', () {
        expect(touchRowHeight(28), kTouchTargetSize);
        expect(touchRowHeight(48), 48);
        expect(touchRowHeight(64), 64, reason: 'never shrinks a taller row');
      });
    });
  }
}
