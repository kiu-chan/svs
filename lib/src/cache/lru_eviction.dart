/// Which of [oldestFirst]'s keys to evict, in order, to bring [currentBytes]
/// (plus [reserve] more about to be added) back to at most [maxBytes] —
/// evict oldest first, stop as soon as the budget is satisfied, and evict
/// nothing at all if the reserved amount alone already exceeds [maxBytes]
/// (a single entry bigger than the whole budget is kept rather than
/// endlessly evicting everything else for no benefit).
///
/// The shared eviction *policy* both `TileCache` and `DiskTileCache` use —
/// each owns its own map and however it disposes an evicted entry
/// (synchronously for an in-memory `ui.Image`, or an async file delete for
/// a disk-backed one), only the "which, and how many" decision is common.
/// Pure: doesn't touch [oldestFirst] or read [byteSizeOf] for any key it
/// doesn't end up evicting.
List<K> pickEvictions<K>(
  Iterable<K> oldestFirst,
  int Function(K key) byteSizeOf, {
  required int currentBytes,
  required int maxBytes,
  int reserve = 0,
}) {
  final evicted = <K>[];
  var bytes = currentBytes;
  for (final key in oldestFirst) {
    if (bytes + reserve <= maxBytes) break;
    bytes -= byteSizeOf(key);
    evicted.add(key);
  }
  return evicted;
}
