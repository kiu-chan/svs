import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:svs/svs.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'svs example',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
      ),
      home: const SvsViewerPage(),
    );
  }
}

/// On native platforms, enter the path to a local .svs (or tiled TIFF) file
/// and view it with pan/zoom, a minimap, and a physical scale bar —
/// everything `SvsImageView` provides out of the box. On the web (no
/// filesystem path to type), a file picker reads the slide's bytes directly
/// and opens it via `SvsFile.openBytes`.
///
/// For a full-featured demo app (file picker, associated-image previews,
/// metadata inspector), see https://github.com/kiu-chan/svs_example.
class SvsViewerPage extends StatefulWidget {
  const SvsViewerPage({super.key});

  @override
  State<SvsViewerPage> createState() => _SvsViewerPageState();
}

class _SvsViewerPageState extends State<SvsViewerPage> {
  final _pathController = TextEditingController();
  SvsFile? _svsFile;
  String? _error;
  bool _loading = false;

  @override
  void dispose() {
    _pathController.dispose();
    unawaited(_svsFile?.close());
    super.dispose();
  }

  Future<void> _openPath() async {
    final path = _pathController.text.trim();
    if (path.isEmpty) return;
    await _open(() => SvsFile.open(path));
  }

  Future<void> _pickAndOpen() async {
    final result = await FilePicker.platform.pickFiles(withData: true);
    final picked = result?.files.single;
    final bytes = picked?.bytes;
    if (bytes == null) return; // cancelled, or a platform that needs a path
    await _open(() => SvsFile.openBytes(bytes));
  }

  Future<void> _open(Future<SvsFile> Function() openIt) async {
    setState(() => _loading = true);
    final previous = _svsFile;
    try {
      final svsFile = await openIt();
      await previous?.close();
      setState(() {
        _svsFile = svsFile;
        _error = null;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('svs example')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: kIsWeb ? _buildWebPicker() : _buildNativePathField(),
          ),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildNativePathField() {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _pathController,
            decoration: const InputDecoration(
              labelText: 'Path to a .svs file',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (_) => _openPath(),
          ),
        ),
        const SizedBox(width: 12),
        FilledButton(
          onPressed: _loading ? null : _openPath,
          child: const Text('Open'),
        ),
      ],
    );
  }

  Widget _buildWebPicker() {
    return Row(
      children: [
        const Expanded(
          child: Text('No filesystem on the web — pick a .svs file instead.'),
        ),
        const SizedBox(width: 12),
        FilledButton(
          onPressed: _loading ? null : _pickAndOpen,
          child: const Text('Pick file'),
        ),
      ],
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final error = _error;
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(error, textAlign: TextAlign.center),
        ),
      );
    }
    final svsFile = _svsFile;
    if (svsFile == null) {
      return Center(
        child: Text(
          kIsWeb
              ? 'Tap "Pick file" above to open a slide.'
              : 'Enter a path above and tap Open.',
        ),
      );
    }
    return SvsImageView(svsFile: svsFile);
  }
}
