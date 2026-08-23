import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:openjpeg_ffi/openjpeg_ffi.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  late final String resultText;

  @override
  void initState() {
    super.initState();
    // No bundled .j2k fixture in this minimal example — this just proves
    // the native call reaches OpenJPEG and a real decode error comes back,
    // which is enough to confirm the FFI wiring itself works end to end.
    // See ../test/openjpeg_ffi_test.dart for a real decode against a real
    // JPEG2000 tile.
    try {
      final image = decodeJ2k(Uint8List(0));
      resultText = 'decoded ${image.width}x${image.height}';
    } on Jp2kDecodeException catch (e) {
      resultText = 'native call reached OpenJPEG, got the expected decode error:\n${e.message}';
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('openjpeg_ffi')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(resultText, style: const TextStyle(fontSize: 18), textAlign: TextAlign.center),
          ),
        ),
      ),
    );
  }
}
