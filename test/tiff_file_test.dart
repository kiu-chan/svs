import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:svs/src/errors.dart';
import 'package:svs/src/tiff/tiff_file.dart';
import 'package:svs/src/tiff/tiff_types.dart';

import 'helpers/tiff_builder.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('svs_tiff_test_');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  Future<TiffFile> openBytes(Uint8List bytes) async {
    final file = File('${tempDir.path}/test.tiff');
    await file.writeAsBytes(bytes);
    final raf = await file.open(mode: FileMode.read);
    return TiffFile.open(raf);
  }

  group('classic TIFF, little-endian', () {
    late TiffFile tiff;

    setUp(() async {
      final bytes = buildTiff(
        bigTiff: false,
        order: Endian.little,
        ifds: [
          [
            TestTag.ints(256, TiffType.short, [100], Endian.little), // ImageWidth, inline
            TestTag.ascii(270, 'Aperio Test|AppMag = 20'), // ImageDescription, out-of-line
            TestTag.ints(324, TiffType.long, [1000, 2000, 3000], Endian.little), // TileOffsets-like, out-of-line
          ],
        ],
      );
      tiff = await openBytes(bytes);
    });

    test('detects byte order and TIFF kind', () {
      expect(tiff.header.byteOrder, Endian.little);
      expect(tiff.header.kind, TiffKind.classic);
      expect(tiff.ifds, hasLength(1));
    });

    test('reads an inline SHORT scalar', () async {
      expect(await tiff.ifds[0].readInt(256), 100);
    });

    test('reads an out-of-line ASCII field, trimmed of its NUL', () async {
      expect(await tiff.ifds[0].readAscii(270), 'Aperio Test|AppMag = 20');
    });

    test('reads an out-of-line LONG array', () async {
      expect(await tiff.ifds[0].readInts(324), [1000, 2000, 3000]);
    });

    test('readInt falls back when the tag is absent', () async {
      expect(await tiff.ifds[0].readInt(999, fallback: 42), 42);
    });

    test('readInt throws when the tag is absent and no fallback given', () async {
      expect(() => tiff.ifds[0].readInt(999), throwsA(isA<SvsFormatException>()));
    });
  });

  test('classic TIFF, big-endian decodes the same as little-endian', () async {
    final bytes = buildTiff(
      bigTiff: false,
      order: Endian.big,
      ifds: [
        [
          TestTag.ints(256, TiffType.long, [654321], Endian.big),
          TestTag.ascii(270, 'Aperio Test|AppMag = 40'),
        ],
      ],
    );
    final tiff = await openBytes(bytes);
    expect(tiff.header.byteOrder, Endian.big);
    expect(await tiff.ifds[0].readInt(256), 654321);
    expect(await tiff.ifds[0].readAscii(270), 'Aperio Test|AppMag = 40');
  });

  test('BigTIFF reads an out-of-line LONG8 array', () async {
    final bytes = buildTiff(
      bigTiff: true,
      order: Endian.little,
      ifds: [
        [
          // 2 x 8 bytes = 16 bytes, exceeds the 8-byte inline field.
          TestTag.ints(324, TiffType.long8, [5000000000, 6000000000], Endian.little),
        ],
      ],
    );
    final tiff = await openBytes(bytes);
    expect(tiff.header.kind, TiffKind.bigTiff);
    expect(await tiff.ifds[0].readInts(324), [5000000000, 6000000000]);
  });

  test('walks a multi-IFD chain in order', () async {
    final bytes = buildTiff(
      bigTiff: false,
      order: Endian.little,
      ifds: [
        [TestTag.ints(256, TiffType.short, [100], Endian.little)],
        [TestTag.ints(256, TiffType.short, [25], Endian.little)],
      ],
    );
    final tiff = await openBytes(bytes);
    expect(tiff.ifds, hasLength(2));
    expect(await tiff.ifds[0].readInt(256), 100);
    expect(await tiff.ifds[1].readInt(256), 25);
  });

  test('throws on a cyclic IFD chain instead of hanging', () async {
    final bytes = buildTiff(
      bigTiff: false,
      order: Endian.little,
      ifds: [
        [TestTag.ints(256, TiffType.short, [1], Endian.little)],
        [TestTag.ints(256, TiffType.short, [2], Endian.little)],
      ],
      nextIfdIndexOverride: {1: 0}, // IFD1 points back at IFD0
    );
    await expectLater(openBytes(bytes), throwsA(isA<SvsFormatException>()));
  });

  test('rejects a file with a bad byte-order marker', () async {
    final bytes = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0, 0]);
    await expectLater(openBytes(bytes), throwsA(isA<SvsFormatException>()));
  });

  test('rejects a file shorter than a TIFF header', () async {
    final bytes = Uint8List.fromList([0x49, 0x49, 0x2A, 0]);
    await expectLater(openBytes(bytes), throwsA(isA<SvsFormatException>()));
  });

  test('concurrent readBytes calls do not interleave on the shared file handle', () async {
    // readBytes does setPosition() then read() as two separate awaits on one
    // shared RandomAccessFile — without serializing them, concurrent callers
    // (e.g. many tiles requested at once while panning) can interleave their
    // setPosition/read pairs and silently read each other's bytes at the
    // wrong offset. This is independent of TIFF semantics, so it's tested
    // directly against readBytes on raw appended payloads.
    final header = buildTiff(
      bigTiff: false,
      order: Endian.little,
      ifds: [
        [TestTag.ints(256, TiffType.short, [1], Endian.little)],
      ],
    );
    const payloadCount = 50;
    const payloadSize = 64;
    final payloads = <Uint8List>[];
    final builder = BytesBuilder()..add(header);
    for (var i = 0; i < payloadCount; i++) {
      final payload = Uint8List(payloadSize)..fillRange(0, payloadSize, i);
      payloads.add(payload);
      builder.add(payload);
    }
    final tiff = await openBytes(builder.toBytes());
    final offsets = List.generate(payloadCount, (i) => header.length + i * payloadSize);

    // Request in reverse order, all at once, to maximize the chance of
    // exposing interleaving if the serialization regresses.
    final indices = List.generate(payloadCount, (i) => payloadCount - 1 - i);
    final futures = [for (final i in indices) tiff.readBytes(offsets[i], payloadSize)];
    final results = await Future.wait(futures);

    for (var k = 0; k < payloadCount; k++) {
      expect(results[k], payloads[indices[k]], reason: 'payload ${indices[k]} came back wrong or from the wrong offset');
    }
  });
}
