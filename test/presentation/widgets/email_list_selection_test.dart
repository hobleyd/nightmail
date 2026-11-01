import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/presentation/widgets/email_list_selection.dart';

const _rows = ['a', 'b', 'c', 'd', 'e'];

void main() {
  group('stepRow', () {
    test('steps down and up', () {
      expect(stepRow(_rows, 'b', 1), 'c');
      expect(stepRow(_rows, 'b', -1), 'a');
    });

    test('stops at either end', () {
      expect(stepRow(_rows, 'e', 1), isNull);
      expect(stepRow(_rows, 'a', -1), isNull);
    });

    test('with nothing selected, Down takes the first row and Up nothing', () {
      expect(stepRow(_rows, null, 1), 'a');
      expect(stepRow(_rows, null, -1), isNull);
    });

    test('a row that has left the list is not stepped from', () {
      expect(stepRow(_rows, 'gone', 1), isNull);
      expect(stepRow(const [], null, 1), isNull);
    });
  });

  group('rangeSelection', () {
    test('spans anchor to cursor in either direction', () {
      expect(rangeSelection(_rows, anchorId: 'b', cursorId: 'd'),
          {'b', 'c', 'd'});
      expect(rangeSelection(_rows, anchorId: 'd', cursorId: 'b'),
          {'b', 'c', 'd'});
      expect(rangeSelection(_rows, anchorId: 'c', cursorId: 'c'), {'c'});
    });

    test('Shift-Down three times then Shift-Up once shrinks the range', () {
      var cursor = 'b';
      for (var i = 0; i < 3; i++) {
        cursor = stepRow(_rows, cursor, 1)!;
      }
      expect(rangeSelection(_rows, anchorId: 'b', cursorId: cursor),
          {'b', 'c', 'd', 'e'});
      cursor = stepRow(_rows, cursor, -1)!;
      expect(rangeSelection(_rows, anchorId: 'b', cursorId: cursor),
          {'b', 'c', 'd'});
    });

    test('reversing past the anchor drops the rows on the far side', () {
      expect(rangeSelection(_rows, anchorId: 'c', cursorId: 'a'),
          {'a', 'b', 'c'});
    });

    test('keeps the picks made before the anchor was set', () {
      expect(
        rangeSelection(_rows,
            anchorId: 'd', cursorId: 'e', base: const {'a', 'd'}),
        {'a', 'd', 'e'},
      );
      // Shrinking back to the anchor still leaves the earlier pick alone.
      expect(
        rangeSelection(_rows,
            anchorId: 'd', cursorId: 'd', base: const {'a', 'd'}),
        {'a', 'd'},
      );
    });

    test('an anchor that left the list leaves just the cursor row', () {
      expect(rangeSelection(_rows, anchorId: 'gone', cursorId: 'c'), {'c'});
    });

    test('a cursor that left the list selects nothing new', () {
      expect(
        rangeSelection(_rows,
            anchorId: 'a', cursorId: 'gone', base: const {'e'}),
        {'e'},
      );
    });
  });
}
