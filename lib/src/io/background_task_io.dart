import 'dart:isolate';

/// Runs [task] on a short-lived background isolate and returns its result,
/// so CPU-heavy work (e.g. encoding a large export) doesn't stall the UI
/// isolate's event loop.
///
/// Everything [task] captures is copied to that isolate, so it must capture
/// only sendable values — plain Dart data, never `dart:ui` objects. The
/// result comes back without a copy.
Future<R> runInBackground<R>(R Function() task) => Isolate.run(task);
