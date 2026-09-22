// Runs on the VM and on the web (`flutter test --platform chrome`). BigTIFF
// stores offsets and counts as 64-bit integers, and dart2js/DDC throw from
// `ByteData.getUint64`/`setUint64` — so everything here goes through
// `MemoryByteSource` (no dart:io), the same path `SvsFile.openBytes` takes.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:svs/src/io/byte_source.dart';
import 'package:svs/src/tiff/tiff_file.dart';
import 'package:svs/src/tiff/tiff_types.dart';
import 'package:svs/src/tiff/tiff_writer.dart';

import 'helpers/tiff_builder.dart';

/// Past 32 bits (a BigTIFF over 4 GB), but exact as a JS number.
const _over4Gb = 5 * 0x100000000 + 7;

const _orders = {'little-endian': Endian.little, 'big-endian': Endian.big};

void main() {
  group('portable 64-bit ByteData access', () {
    test('reads known little- and big-endian byte patterns', () {
      final bytes = Uint8List.fromList([
        0x00, 0x0F, 0x0E, 0x0D, 0x0C, 0x0B, 0x0A, 0x00, //
      ]);
      final data = ByteData.sublistView(bytes);
      expect(data.getUint64Portable(0, Endian.little), 0x0A0B0C0D0E0F00);
      expect(data.getUint64Portable(0, Endian.big), 0x0F0E0D0C0B0A00);
    });

    test('reads signed values', () {
      final data = ByteData(8);
      for (var i = 0; i < 8; i++) {
        data.setUint8(i, 0xFF);
      }
      expect(data.getInt64Portable(0, Endian.little), -1);
      expect(data.getInt64Portable(0, Endian.big), -1);

      // -(2^32 + 1): high half 0xFFFFFFFE, low half 0xFFFFFFFF.
      data.setUint32(0, 0xFFFFFFFF, Endian.little);
      data.setUint32(4, 0xFFFFFFFE, Endian.little);
      expect(data.getInt64Portable(0, Endian.little), -0x100000001);
    });

    for (final MapEntry(key: name, value: order) in _orders.entries) {
      test('round-trips through setUint64Portable ($name)', () {
        for (final value in [
          0,
          1,
          0xFFFFFFFF,
          0x100000000,
          _over4Gb,
          0x1FFFFFFFFFFFFF, // 2^53 - 1
        ]) {
          final data = ByteData(12);
          data.setUint64Portable(2, value, order);
          expect(data.getUint64Portable(2, order), value);
          expect(data.getInt64Portable(2, order), value);
        }
      });
    }
  });

  for (final MapEntry(key: name, value: order) in _orders.entries) {
    test('parses a BigTIFF from memory ($name)', () async {
      final bytes = buildTiff(
        bigTiff: true,
        order: order,
        ifds: [
          [
            TestTag.ints(256, TiffType.long, [100], order),
            TestTag.ascii(270, 'Aperio Test|AppMag = 20'),
            TestTag.ints(324, TiffType.long8, [16, _over4Gb, 42], order),
          ],
          [
            TestTag.ints(256, TiffType.short, [50], order),
          ],
        ],
      );

      final tiff = await TiffFile.open(MemoryByteSource(bytes));
      addTearDown(tiff.close);

      expect(tiff.header.kind, TiffKind.bigTiff);
      expect(tiff.ifds, hasLength(2));
      expect(await tiff.ifds[0].readInt(256), 100);
      expect(await tiff.ifds[0].readAscii(270), 'Aperio Test|AppMag = 20');
      expect(await tiff.ifds[0].readInts(324), [16, _over4Gb, 42]);
      expect(await tiff.ifds[1].readInt(256), 50);
    });
  }

  test('planPyramidHeader output reads back, patched offsets '
      'included', () async {
    final layout = planPyramidHeader(const [
      PyramidLevelSpec(
        width: 1000,
        height: 600,
        tileWidth: 256,
        tileLength: 256,
        compression: 7,
        imageDescription: 'Aperio Image Library|AppMag = 40',
      ),
      PyramidLevelSpec(
        width: 500,
        height: 300,
        tileWidth: 256,
        tileLength: 256,
        compression: 7,
      ),
    ]);

    // What the export does once its tiles are streamed: seek back and
    // write the real TileOffsets (LONG8) and TileByteCounts (LONG).
    final header = layout.headerBytes;
    final level0Offsets = List.generate(
      layout.levels[0].tileCount,
      (i) => _over4Gb + i * 1000,
    );
    final level0Counts = List.generate(
      layout.levels[0].tileCount,
      (i) => 900 + i,
    );
    void patch(int pos, Uint8List value) =>
        header.setRange(pos, pos + value.length, value);
    patch(
      layout.levels[0].tileOffsetsValuePos,
      encodeTiffInts(level0Offsets, TiffType.long8),
    );
    patch(
      layout.levels[0].tileByteCountsValuePos,
      encodeTiffInts(level0Counts, TiffType.long),
    );

    final tiff = await TiffFile.open(MemoryByteSource(header));
    addTearDown(tiff.close);

    expect(tiff.header.kind, TiffKind.bigTiff);
    expect(tiff.ifds, hasLength(2));
    final level0 = tiff.ifds[0];
    expect(await level0.readInt(256), 1000);
    expect(await level0.readInt(257), 600);
    expect(await level0.readAscii(270), 'Aperio Image Library|AppMag = 40');
    expect(await level0.readInts(324), level0Offsets);
    expect(await level0.readInts(325), level0Counts);
    expect(await tiff.ifds[1].readInt(256), 500);
    expect(
      await tiff.ifds[1].readInts(324),
      List.filled(layout.levels[1].tileCount, 0),
    );
  });
}
