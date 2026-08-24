import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:svs/svs.dart';
import 'package:svs/src/tiff/tiff_types.dart';

import 'helpers/tiff_builder.dart';

/// A generous-but-bounded timeout for every test here — short enough that a
/// genuine hang (e.g. real `dart:io`/`dart:ui` async work run outside
/// `tester.runAsync`, which never resolves inside `testWidgets`' fake-async
/// zone — see the `runAsync` tests below) fails fast during development
/// instead of burning the default 10-minute `testWidgets` timeout.
const _testTimeout = Timeout(Duration(seconds: 20));

/// A tiled, all-sparse (zero tile byte counts) source `.svs` fixture — no
/// real tile pixel data, so no `dart:ui` decode ever actually runs. Enough
/// for anything that only cares about the view's pan/zoom transform or
/// static layout, not about what's actually painted.
Future<SvsFile> _openTestFile(Directory dir, {String name = 'test.svs'}) async {
  const width = 2000, height = 2000, tileSize = 256;
  final tilesX = (width / tileSize).ceil();
  final tilesY = (height / tileSize).ceil();
  final tileCount = tilesX * tilesY;
  final tags = [
    TestTag.ints(256, TiffType.long, [width], Endian.little),
    TestTag.ints(257, TiffType.long, [height], Endian.little),
    TestTag.ints(259, TiffType.short, [7], Endian.little),
    TestTag.ints(322, TiffType.long, [tileSize], Endian.little),
    TestTag.ints(323, TiffType.long, [tileSize], Endian.little),
    TestTag.ints(
      324,
      TiffType.long,
      List.generate(tileCount, (i) => 10000 + i * 100),
      Endian.little,
    ),
    TestTag.ints(
      325,
      TiffType.long,
      List.generate(tileCount, (i) => 0), // sparse: byte count 0
      Endian.little,
    ),
  ];
  final bytes = buildTiff(bigTiff: false, order: Endian.little, ifds: [tags]);
  final file = File('${dir.path}/$name');
  await file.writeAsBytes(bytes);
  return SvsFile.open(file.path);
}

/// Same level fixture as [_openTestFile], plus a real, decodable thumbnail
/// associated image (a solid-fill JPEG strip) — needed to exercise the
/// minimap, which only ever shows once a thumbnail has actually decoded.
Future<SvsFile> _openTestFileWithThumbnail(Directory dir) async {
  const width = 2000, height = 2000, tileSize = 256;
  final tilesX = (width / tileSize).ceil();
  final tilesY = (height / tileSize).ceil();
  final tileCount = tilesX * tilesY;
  final levelTags = [
    TestTag.ints(256, TiffType.long, [width], Endian.little),
    TestTag.ints(257, TiffType.long, [height], Endian.little),
    TestTag.ints(259, TiffType.short, [7], Endian.little),
    TestTag.ints(322, TiffType.long, [tileSize], Endian.little),
    TestTag.ints(323, TiffType.long, [tileSize], Endian.little),
    TestTag.ints(
      324,
      TiffType.long,
      List.generate(tileCount, (i) => 10000 + i * 100),
      Endian.little,
    ),
    TestTag.ints(
      325,
      TiffType.long,
      List.generate(tileCount, (i) => 0), // sparse: byte count 0
      Endian.little,
    ),
  ];

  final thumb = img.Image(width: 32, height: 24);
  img.fill(thumb, color: img.ColorRgb8(120, 60, 200));
  final thumbJpeg = img.encodeJpg(thumb, quality: 90);

  List<TestTag> associatedTags(int stripOffset) => [
    TestTag.ints(256, TiffType.long, [32], Endian.little),
    TestTag.ints(257, TiffType.long, [24], Endian.little),
    TestTag.ints(259, TiffType.short, [7], Endian.little), // JPEG
    TestTag.ints(273, TiffType.long, [stripOffset], Endian.little),
    TestTag.ints(279, TiffType.long, [thumbJpeg.length], Endian.little),
  ];

  // Two-pass layout: the strip offset is a single inline LONG value, so it
  // can't change the header's byte length — measure it once with a
  // placeholder offset, then rebuild with the tile's real (now-known) offset.
  final headerOnly = buildTiff(
    bigTiff: false,
    order: Endian.little,
    ifds: [levelTags, associatedTags(0)],
  );
  final header = buildTiff(
    bigTiff: false,
    order: Endian.little,
    ifds: [levelTags, associatedTags(headerOnly.length)],
  );

  final file = File('${dir.path}/test_with_thumb.svs');
  await file.writeAsBytes([...header, ...thumbJpeg]);
  return SvsFile.open(file.path);
}

/// Runs [callback] with the test's actual viewport set to 400x400 logical
/// pixels. A bare `SizedBox(width: 400, height: 400)` at the root of
/// `pumpWidget`'s tree does *not* achieve this on its own — the root gets
/// tight constraints matching the full test surface (800x600 by default),
/// which a `SizedBox` can't override — so every test here that cares about
/// the *exact* viewport size (not just a before/after comparison) needs the
/// view itself resized, via [WidgetTester.view].
void _testWidgets(
  String description,
  Future<void> Function(WidgetTester tester) callback, {
  Timeout? timeout,
}) {
  testWidgets(description, (tester) async {
    tester.view.physicalSize = const Size(400, 400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await callback(tester);
  }, timeout: timeout);
}

Widget _wrap(Widget child) =>
    Directionality(textDirection: TextDirection.ltr, child: child);

/// Finds the zoom-percent HUD's label text (e.g. `'100%'`) — distinct from
/// the chip's own glyph box, which separately renders a bare `'%'` `Text`.
final Finder _zoomPercentFinder = find.byWidgetPredicate(
  (w) => w is Text && w.data != null && RegExp(r'^\d+%$').hasMatch(w.data!),
);

/// Reads the zoom-percent HUD's current text (e.g. `'100%'`).
String _zoomPercentText(WidgetTester tester) =>
    tester.widget<Text>(_zoomPercentFinder).data!;

/// The minimap is a private widget (`_Minimap`) — matched by its runtime
/// type name since there's no public type to check against.
Finder _minimapFinder() =>
    find.byWidgetPredicate((w) => '${w.runtimeType}' == '_Minimap');

/// Simulates a two-finger pinch-out: both pointers down close together, one
/// dragged outward, both released — the gesture [SvsImageView]'s pan/zoom
/// responds to via `onScaleUpdate`.
Future<void> _pinchOut(WidgetTester tester) async {
  final pointerA = await tester.startGesture(const Offset(150, 150));
  final pointerB = await tester.startGesture(const Offset(250, 250));
  await tester.pump(const Duration(milliseconds: 20));
  await pointerB.moveTo(const Offset(350, 350));
  await tester.pump(const Duration(milliseconds: 20));
  await pointerA.up();
  await pointerB.up();
  await tester.pump(const Duration(milliseconds: 20));
}

void main() {
  late Directory tempDir;
  late SvsFile svs;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('svs_image_view_test_');
    svs = await _openTestFile(tempDir);
  });

  tearDown(() async {
    await svs.close();
    await tempDir.delete(recursive: true);
  });

  group('pan/zoom vs. annotation drawing', () {
    _testWidgets('a pinch gesture zooms the view when not drawing', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(SvsImageView(svsFile: svs)));
      await tester.pump();
      final before = _zoomPercentText(tester);

      await _pinchOut(tester);
      await tester.pump();
      final after = _zoomPercentText(tester);

      expect(after, isNot(before));
    }, timeout: _testTimeout);

    _testWidgets(
      'the same pinch gesture leaves zoom unchanged while drawing a point annotation',
      (tester) async {
        final controller = SvsAnnotationController()
          ..drawMode = SvsAnnotationDrawMode.point;
        addTearDown(controller.dispose);

        await tester.pumpWidget(
          _wrap(SvsImageView(svsFile: svs, annotationController: controller)),
        );
        await tester.pump();
        final before = _zoomPercentText(tester);

        await _pinchOut(tester);
        await tester.pump();
        final after = _zoomPercentText(tester);

        expect(after, before);
      },
      timeout: _testTimeout,
    );

    _testWidgets(
      'the same pinch gesture leaves zoom unchanged while drawing a polyline annotation',
      (tester) async {
        final controller = SvsAnnotationController()
          ..drawMode = SvsAnnotationDrawMode.polyline;
        addTearDown(controller.dispose);

        await tester.pumpWidget(
          _wrap(SvsImageView(svsFile: svs, annotationController: controller)),
        );
        await tester.pump();
        final before = _zoomPercentText(tester);

        await _pinchOut(tester);
        await tester.pump();
        final after = _zoomPercentText(tester);

        expect(after, before);
      },
      timeout: _testTimeout,
    );

    _testWidgets('switching drawMode mid-session (no other rebuild in between) '
        'suppresses the very next gesture', (tester) async {
      final controller = SvsAnnotationController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        _wrap(SvsImageView(svsFile: svs, annotationController: controller)),
      );
      await tester.pump();

      // Flip drawMode — nothing else triggers a rebuild here. If the
      // gesture layer only picked this up on some later, unrelated
      // rebuild (e.g. the one a zoom/pan itself causes), the pinch right
      // below would still land as an ordinary zoom instead of being
      // suppressed.
      controller.drawMode = SvsAnnotationDrawMode.point;

      final before = _zoomPercentText(tester);
      await _pinchOut(tester);
      await tester.pump();
      expect(_zoomPercentText(tester), before);
    }, timeout: _testTimeout);

    _testWidgets(
      'a pinch still zooms normally with a controller attached but idle '
      '(drawMode.none) — regression test for a real gesture-arena bug',
      (tester) async {
        // Previously, an annotationController being attached at all wired up
        // GestureDetector's onTapUp (a TapGestureRecognizer) alongside
        // onScaleStart/Update/End (a ScaleGestureRecognizer) even in
        // drawMode.none, where pan/zoom must keep working. The two
        // recognizers competing for the same pointer made the scale
        // recognizer's own scale-ratio math unreliable — this exact pinch
        // used to compute scale == 1.0 (no zoom at all) despite two fingers
        // clearly moving apart. See _onPointerDown's doc comment for the fix
        // (tap detection moved off GestureDetector's tap recognizer
        // entirely, onto raw Listener pointer events).
        final controller = SvsAnnotationController();
        addTearDown(controller.dispose);

        await tester.pumpWidget(
          _wrap(SvsImageView(svsFile: svs, annotationController: controller)),
        );
        await tester.pump();
        final before = _zoomPercentText(tester);

        await _pinchOut(tester);
        await tester.pump();

        expect(_zoomPercentText(tester), isNot(before));
      },
      timeout: _testTimeout,
    );
  });

  group('tap handling (drawMode.none and drawMode.point)', () {
    // The 2000x2000 level fits exactly into the 400x400 viewport at 0.2x
    // (see _initializeView), landing the origin at (0,0) — so screen point
    // (sx, sy) is level-0 point (sx / 0.2, sy / 0.2).
    const tapScreenPoint = Offset(200, 200);
    const tappedLevel0Point = Offset(1000, 1000);

    _testWidgets('a stationary tap selects the annotation under it', (
      tester,
    ) async {
      final controller = SvsAnnotationController();
      addTearDown(controller.dispose);
      final annotation = SvsAnnotation(
        type: SvsAnnotationShapeType.point,
        points: const [tappedLevel0Point],
      );
      controller.add(annotation);

      SvsAnnotation? tapped;
      var tappedCallbackCount = 0;
      await tester.pumpWidget(
        _wrap(
          SvsImageView(
            svsFile: svs,
            annotationController: controller,
            onAnnotationTap: (a) {
              tapped = a;
              tappedCallbackCount++;
            },
          ),
        ),
      );
      await tester.pump();

      await tester.tapAt(tapScreenPoint);
      await tester.pump();

      expect(controller.selectedId, annotation.id);
      expect(tapped?.id, annotation.id);
      expect(tappedCallbackCount, 1);
    }, timeout: _testTimeout);

    _testWidgets(
      'a tap in drawMode.point commits a new point annotation',
      (tester) async {
        final controller = SvsAnnotationController()
          ..drawMode = SvsAnnotationDrawMode.point;
        addTearDown(controller.dispose);

        await tester.pumpWidget(
          _wrap(SvsImageView(svsFile: svs, annotationController: controller)),
        );
        await tester.pump();

        expect(controller.annotations, isEmpty);
        await tester.tapAt(tapScreenPoint);
        await tester.pump();

        expect(controller.annotations, hasLength(1));
        expect(
          controller.annotations.single.type,
          SvsAnnotationShapeType.point,
        );
        expect(controller.annotations.single.points.single, tappedLevel0Point);
      },
      timeout: _testTimeout,
    );

    _testWidgets(
      'a two-finger gesture is never mistaken for a tap, even if one '
      'finger lifts without moving',
      (tester) async {
        final controller = SvsAnnotationController();
        addTearDown(controller.dispose);
        final annotation = SvsAnnotation(
          type: SvsAnnotationShapeType.point,
          points: const [tappedLevel0Point],
        );
        controller.add(annotation);

        await tester.pumpWidget(
          _wrap(SvsImageView(svsFile: svs, annotationController: controller)),
        );
        await tester.pump();

        // Pointer A stays put exactly on the annotation (would be a tap
        // hit-testing it, if this were mistakenly treated as one); pointer
        // B moves — a pinch. A lifts first without ever moving.
        final pointerA = await tester.startGesture(tapScreenPoint);
        final pointerB = await tester.startGesture(const Offset(250, 250));
        await tester.pump(const Duration(milliseconds: 20));
        await pointerB.moveTo(const Offset(350, 350));
        await tester.pump(const Duration(milliseconds: 20));
        await pointerA.up();
        await tester.pump(const Duration(milliseconds: 20));
        await pointerB.up();
        await tester.pump(const Duration(milliseconds: 20));

        expect(controller.selectedId, isNull);
      },
      timeout: _testTimeout,
    );
  });

  group('display options', () {
    _testWidgets('showZoomLevel: false hides the zoom percentage', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(SvsImageView(svsFile: svs, showZoomLevel: false)),
      );
      await tester.pump();

      expect(find.textContaining('%'), findsNothing);
    }, timeout: _testTimeout);

    _testWidgets('showZoomLevel: true (the default) shows it', (tester) async {
      await tester.pumpWidget(_wrap(SvsImageView(svsFile: svs)));
      await tester.pump();

      expect(_zoomPercentFinder, findsOneWidget);
    }, timeout: _testTimeout);

    // Both tests below touch real file I/O beyond what `setUp` already did
    // (opening a second fixture, and — for the first test — the thumbnail's
    // real `dart:ui` JPEG decode kicked off from initState, which itself
    // reads more bytes off disk). `testWidgets` runs its body in a
    // fake-async zone that real `dart:io`/`dart:ui` async work never
    // resolves in — every bit of it (fixture open, pumpWidget, and the
    // settle delay) has to happen inside one `tester.runAsync` call, not
    // just part of it, or it hangs until the test framework's own timeout.
    _testWidgets(
      'the minimap shows by default when a thumbnail exists',
      (tester) async {
        await tester.runAsync(() async {
          final svsWithThumb = await _openTestFileWithThumbnail(tempDir);
          addTearDown(svsWithThumb.close);
          await tester.pumpWidget(_wrap(SvsImageView(svsFile: svsWithThumb)));
          await Future<void>.delayed(const Duration(milliseconds: 300));
        });
        await tester.pump();

        expect(_minimapFinder(), findsOneWidget);
      },
      timeout: _testTimeout,
    );

    _testWidgets(
      'showMinimap: false hides the minimap and never decodes a thumbnail',
      (tester) async {
        await tester.runAsync(() async {
          final svsWithThumb = await _openTestFileWithThumbnail(tempDir);
          addTearDown(svsWithThumb.close);
          await tester.pumpWidget(
            _wrap(SvsImageView(svsFile: svsWithThumb, showMinimap: false)),
          );
          await Future<void>.delayed(const Duration(milliseconds: 300));
        });
        await tester.pump();

        expect(_minimapFinder(), findsNothing);
      },
      timeout: _testTimeout,
    );
  });
}
