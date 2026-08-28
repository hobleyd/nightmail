import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/core/utils/dropdown_placement.dart';

void main() {
  group('dropdownWidthFor', () {
    test('keeps the preferred width when the window has room', () {
      expect(
        dropdownWidthFor(preferredWidth: 400, surfaceWidth: 1200),
        400,
      );
    });

    test('narrows to the window less both insets', () {
      expect(
        dropdownWidthFor(preferredWidth: 400, surfaceWidth: 300),
        300 - kDropdownEdgeInset * 2,
      );
    });

    test('gives up rather than returning a negative width', () {
      expect(dropdownWidthFor(preferredWidth: 400, surfaceWidth: 8), 400);
    });
  });

  group('dropdownHorizontalShift', () {
    test('does not move a panel that already fits', () {
      expect(
        dropdownHorizontalShift(
          targetLeft: 100,
          dropdownWidth: 400,
          surfaceWidth: 1200,
        ),
        0,
      );
    });

    test('pulls an overflowing panel back to the inset', () {
      // Field near the right edge: 900 + 400 = 1300, past 1200 - 8.
      final dx = dropdownHorizontalShift(
        targetLeft: 900,
        dropdownWidth: 400,
        surfaceWidth: 1200,
      );
      expect(dx, lessThan(0));
      expect(900 + dx + 400, 1200 - kDropdownEdgeInset);
    });

    test('leaves a panel ending exactly on the inset alone', () {
      expect(
        dropdownHorizontalShift(
          targetLeft: 1200 - kDropdownEdgeInset - 400,
          dropdownWidth: 400,
          surfaceWidth: 1200,
        ),
        0,
      );
    });

    test('pins the left edge when the panel cannot fit either way', () {
      // Window narrower than the panel: showing the left edge wins, since the
      // list is left-aligned text.
      final dx = dropdownHorizontalShift(
        targetLeft: 2,
        dropdownWidth: 400,
        surfaceWidth: 300,
      );
      expect(2 + dx, kDropdownEdgeInset);
    });

    test('never overshoots past the left inset', () {
      for (final left in [0.0, 5.0, 8.0, 60.0, 700.0, 1150.0]) {
        final width = dropdownWidthFor(
          preferredWidth: 400,
          surfaceWidth: 1200,
        );
        final dx = dropdownHorizontalShift(
          targetLeft: left,
          dropdownWidth: width,
          surfaceWidth: 1200,
        );
        expect(left + dx, greaterThanOrEqualTo(kDropdownEdgeInset - 0.001),
            reason: 'left=$left');
        expect(left + dx + width, lessThanOrEqualTo(1200 - kDropdownEdgeInset + 0.001),
            reason: 'left=$left');
      }
    });
  });
}
