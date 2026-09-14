/// Runs [task] on the calling thread: the web has no isolates to move it to.
Future<R> runInBackground<R>(R Function() task) async => task();
