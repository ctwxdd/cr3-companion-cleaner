# AI development instructions

CR3 Companion Cleaner is a safety-critical photo utility. Preserve user data
first, then optimize for responsiveness, bounded memory, and minimal avoidable
storage I/O. The app is intentionally designed to reduce SSD/NVMe writes,
swapfile growth, memory-card pressure, and repeated full-library scans.

## Non-negotiable behavior

- Never permanently delete user media. Use macOS Trash APIs and keep Dry Run on
  by default.
- Never modify JPG/JPEG companions. Never trash a CR3 that still has a valid
  companion under the pairing rules.
- Backup never writes to the camera card, never overwrites a destination, and
  must keep the partial-file + SHA-256 verification + atomic rename workflow.
- Hidden files, AppleDouble `._` resource forks, Trash, and system index
  locations must remain excluded.
- All long operations must remain cancellable and off the main actor.

## Performance and storage longevity

- Avoid full rescans when an indexed or folder-scoped update is sufficient.
  Reuse the last-run and SHA-256 caches only when size, timestamps, file ID, and
  volume ID still match.
- Do not add cache writes on every progress update or file. Persist only changed
  metadata, write it once per completed operation, and use atomic writes.
- Stream large files sequentially. Do not replace the 4 MiB chunked hashing and
  copy loops with whole-file `Data(contentsOf:)`, memory mapping, or unbounded
  buffering.
- Keep an `autoreleasepool` around every Foundation file chunk. Removing it can
  retain `NSData` buffers, create tens of gigabytes of swap, and cause heavy
  SSD/NVMe writes.
- Keep `F_NOCACHE` for one-pass large-file streams so camera-card and backup
  scans do not evict useful macOS cache pages.
- Parallelize CPU/Neural Engine image analysis with the existing adaptive,
  thermally aware limits. Do not parallelize multiple full-file streams from
  the same SD card or hard drive merely to increase headline throughput.
- Decode downsampled thumbnails on demand, coalesce duplicate requests, bound
  memory caches, and preload only a small neighborhood around the active photo.
- Never cache original photo or video bytes. Cache only bounded previews,
  results, hashes, and lightweight file metadata.
- Treat sustained memory growth or swap activity as a regression even when the
  operation eventually completes.

## Change checklist

1. Trace every caller before changing shared scan, cache, copy, hashing, Trash,
   or Web Remote behavior.
2. Prefer native Swift, SwiftUI, Foundation, Vision, Core ML, and AppKit APIs;
   add no dependency when the platform already provides the feature.
3. Keep concurrency bounded and cancellation-aware. Capture source and
   destination URLs at operation start so UI changes cannot redirect work.
4. Test both matching and failure paths. Backup changes must prove that copied
   bytes are verified before success is reported.
5. Run the relevant smoke test plus arm64 and x86_64 type checks. For streaming
   changes, retain the 512 MiB regression check: bounded RSS, zero swaps, and no
   accumulation proportional to file size.

Generated apps, archives, model-conversion environments, and build artifacts
belong in ignored `outputs/` or `work/`, not in Git history.
