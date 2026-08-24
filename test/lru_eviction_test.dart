import 'package:flutter_test/flutter_test.dart';
import 'package:svs/src/cache/lru_eviction.dart';

void main() {
  group('pickEvictions', () {
    test('evicts nothing when already under budget', () {
      final victims = pickEvictions(
        ['a', 'b'],
        (k) => 10,
        currentBytes: 20,
        maxBytes: 100,
        reserve: 5,
      );
      expect(victims, isEmpty);
    });

    test('evicts oldest-first, stopping as soon as budget is satisfied', () {
      // Entries in oldest-to-newest order, 10 bytes each; budget 25, adding
      // one more 10-byte entry (currentBytes 30 already exceeds budget on
      // its own) should evict just enough (the two oldest) to fit.
      final victims = pickEvictions(
        ['oldest', 'middle', 'newest'],
        (k) => 10,
        currentBytes: 30,
        maxBytes: 25,
        reserve: 10,
      );
      expect(victims, ['oldest', 'middle']);
    });

    test('evicts nothing when there is nothing to evict against an '
        'oversized reserve alone', () {
      final victims = pickEvictions(
        const <String>[],
        (k) => 10,
        currentBytes: 0,
        maxBytes: 10,
        reserve: 50,
      );
      expect(victims, isEmpty);
    });

    test('evicts everything available rather than looping forever if the '
        'budget still can\'t be satisfied', () {
      final victims = pickEvictions(
        ['a', 'b'],
        (k) => 10,
        currentBytes: 20,
        maxBytes: 5,
        reserve: 100,
      );
      expect(victims, ['a', 'b']);
    });

    test('never reads byteSizeOf for a key it does not evict', () {
      final read = <String>[];
      pickEvictions(
        ['a', 'b', 'c'],
        (k) {
          read.add(k);
          return 10;
        },
        currentBytes: 10,
        maxBytes: 20,
        reserve: 0, // already under budget: nothing should be evicted at all
      );
      expect(read, isEmpty);
    });
  });
}
