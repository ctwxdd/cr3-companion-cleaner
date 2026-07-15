# CR3 Companion Cleaner

A native macOS 13+ SwiftUI utility that finds Canon `.CR3` files without a
same-name `.JPG`/`.JPEG` companion and, after confirmation, moves those RAW
files and their listed same-name `.XMP` sidecars to the macOS Trash.

When a CR3 is inside an immediate `RAW`, `CR3`, or `ARW` folder (case
insensitive), a matching JPG/JPEG in the parent folder also protects it.

## Build

1. Open `CR3 Companion Cleaner.xcodeproj` in Xcode.
2. Select the **CR3 Companion Cleaner** scheme and **My Mac**.
3. Run with **⌘R**, or run tests with **⌘U**.

Dry Run is enabled by default. The app uses `FileManager.trashItem`; it never
permanently deletes files and never changes JPG/JPEG files. An XMP is moved
only after its orphaned CR3 was moved successfully.

## Performance and storage longevity

Performance is a product requirement, not an afterthought. The app is designed
to remain responsive across libraries with tens of thousands of files while
minimizing avoidable reads, writes, cache pollution, swap growth, and wear on
internal SSD/NVMe storage and removable camera media.

- Scans read lightweight metadata first and hash contents only for plausible
  same-name, same-size matches.
- Large hashes and backups use constant-memory 4 MiB sequential streams with a
  per-chunk autorelease pool. This prevents retained Foundation buffers from
  expanding swapfiles on the internal SSD.
- One-pass streams use `F_NOCACHE` to avoid flooding the macOS file cache with
  media that is unlikely to be reread immediately.
- Verified hashes and analysis results are reused only while file and volume
  identity remain unchanged. Cache metadata is written once per changed run,
  not once per file or progress update.
- Image decoding is downsampled, deduplicated, demand-driven, and held in
  bounded caches. Only a small group around the current photo is preloaded.
- CPU/Core ML work scales with the machine and thermal state, while full-file
  storage streams remain deliberately conservative—especially on SD cards and
  spinning disks.
- Backup reads each source once while writing a hidden partial file, reads the
  destination back for SHA-256 verification, then atomically renames it. It
  avoids a redundant third pass while still detecting silent copy failures.

These measures reduce unnecessary storage activity; they cannot eliminate the
normal writes required to create a backup. Contributor and AI-agent constraints
that protect these properties are documented in [`AGENTS.md`](AGENTS.md).

The **Blur Review** tab runs the bundled Core ML model and Apple Vision entirely
on-device over JPG/JPEG previews. It flags likely blur, possible closed eyes or
blinks, and low face-capture quality. Small or low-confidence faces are ignored
and the conservative quality threshold reduces false positives. **Group Bursts** switches the table to
photos captured in the same folder within 1.5 seconds of one another. Select one
or more photos, press **Space** for Quick Look, use **↑/↓** to browse, and press
**Delete** to review moving only the selection to the macOS Trash. Dry Run still
applies and nothing is moved without confirmation. After a successful move, the
next photo is selected automatically and an open Quick Look panel follows it. The `BlurDetecting` protocol and
`BlurModelConfiguration` keep model-specific details out of scanning and UI;
see `CR3 Companion Cleaner/Models/README.md` for the replacement contract.

The review filter can show all flags, strong blur (75%+), any blur flag,
possible closed eyes/blinks, or low face quality. The most recent actual review
deletion can be restored with **⌘Z**. Review deletion uses `NSWorkspace.recycle`
to retain the exact Trash URL; undo never overwrites an existing original path.

Additional first-pass filters flag severely underexposed or overexposed photos,
images below 2 megapixels, and byte-for-byte duplicates. Duplicate hashing is
limited to same-size candidates before SHA-256, avoiding unnecessary full-file
reads. Burst groups rank a recommended best frame using sharpness, open-eye,
face-quality, exposure, and resolution signals; ranking never deletes photos.

Analysis uses a bounded Swift task group sized dynamically from active CPU
cores, physical memory, Low Power Mode, and thermal state (2–12 workers). Core
ML uses `.all` compute units so Apple Silicon can schedule inference across the
CPU, GPU, and Neural Engine without creating one task per file or allowing
unbounded memory use.

The latest folder's RAW scan and photo analysis are cached as JSON in the app's
macOS cache directory. Re-selecting that folder restores results immediately
and filters files that no longer exist. Cancelling a re-scan/re-analysis also
restores the previous cached results. RAW cleanup still re-checks JPG/JPEG
companions immediately before moving anything to Trash, so cached data cannot
bypass the safety rule.

**Web Remote** starts an opt-in local HTTP session for phones on the same Wi-Fi.
The Mac displays a QR code, six-digit pairing PIN, and local address. After login,
the responsive page shows filtered thumbnail grids and a 1600-pixel quick
preview with swipe/previous/next navigation, an iPhone Photos-style scrollable
filmstrip, **Keep & Next**, Dry Run, Trash,
and Undo. Moving the current preview to Trash advances to the next photo.
**Browse Photos** builds a lightweight recursive JPG/JPEG index without running
AI analysis. Choose **Browse all photos (no AI)** to cull from the same grid,
filmstrip, Trash, and Undo workflow; images are still decoded only on demand.
Browse thumbnails use tight spacing and preserve portrait/landscape aspect
ratios. Phone pinch gestures zoom and pan only the preview image while controls
stay fixed. The macOS **Browse Photos** tab provides the same on-demand grid,
main preview, filmstrip, trackpad pinch zoom, keyboard navigation, Trash, and
Undo workflow. **Choose Subfolder…** and **Up** switch within the originally
authorized root without reopening access to unrelated folders.
The server generates previews concurrently and preloads the previous/next three
images. When a JPG is moved, only its matching CR3 locations are rechecked and
new RAW orphans appear immediately without a full scan.
The RAW tab also shows lazy-loaded JPEG previews generated locally from each
orphaned CR3. Select one or more RAW files, or act from the full-screen preview,
to review the CR3/XMP count and total size before asking the Mac to move only
those items to Trash. Dry Run remains the default and JPG files are never
modified. RAW cleanup reports its moved/failed counts and first failure reason
on the phone.
It exposes only opaque IDs for analyzed JPG/JPEG candidates in the chosen folder;
there is no arbitrary file route and the server stops when the app exits.
It publishes `_cr3cleaner._tcp` through Bonjour so macOS requests the required
Local Network privacy permission when the remote is first started.
After the Mac authorizes a root folder, the phone can explicitly browse and
select only visible descendant folders inside that root, then start either the
RAW companion scan or local AI photo analysis. Relative paths are validated
again on the Mac and cannot escape the authorized root.

The mobile **Backup** tab can run Backup Check, show required and available
space, and confirm a verified backup after the memory card and destination have
been authorized on the Mac. Web Remote uses the stable
`http://<Mac-name>.local:8765` address and retains its HttpOnly pairing cookie
for one year, so a paired phone reconnects after normal App restarts without
scanning the QR code again. Choosing **Stop Web Remote** on the Mac revokes the
saved pairing.

After choosing a folder, RAW scanning and local photo analysis are independent:
switch between the two result tabs and start either task first. Cleanup results
stay inside the RAW tab instead of replacing the photo review screen. Switching
away from a folder that has scan or analysis results asks for confirmation.

**Backup Check** lets you independently choose a mounted camera memory card and
a designated backup destination. If no destination is designated, the current
photo folder is used as the backup library. It recursively indexes every
visible, readable regular file—including RAW, photos, videos, audio, and
sidecars—then confirms a backup only when the
case-insensitive filename, byte size, and SHA-256 file contents all match.
Hashing is limited to same-name/same-size candidates, so unrelated large files
are never read in full. Hidden files, AppleDouble resource forks, and Trash
folders are skipped. Checking is read-only; the memory card is never modified.

Verified SHA-256 values are retained in a small last-run cache and reused only
while file size, modification/creation times, file identity, and volume identity
remain unchanged. The cache is written once only when new hashes were computed;
a repeated unchanged check performs no large-file reads and no cache write.
First-run hashing uses one sequential stream per file with macOS file-cache
pollution disabled, avoiding random-seek or multi-reader pressure on SD cards
and hard drives.
Every 4 MB Foundation read is enclosed in its own autorelease pool, so hashing
large libraries keeps constant memory instead of retaining chunk buffers and
forcing macOS to create large swapfiles. Backup copying and duplicate hashing
use the same bounded-lifetime rule.

After a check, **Back Up Missing…** preflights the exact required byte count,
destination-volume free capacity, and projected remaining capacity. Confirmed
copies are placed under `<backup folder>/<memory card name>/` while preserving
the card's relative folder structure and file dates. Existing destinations are
never overwritten. Each source is read once into a hidden partial file, SHA-256
verified from the destination volume, then atomically renamed; cancellation or
failure removes only that app-created partial file. Successful rows immediately
change to Backed Up without requiring another full scan.

RAW scans, backup checks/copies, photo indexing/analysis, and Trash operations
use a scoped macOS `ProcessInfo` activity to prevent automatic idle sleep while
storage I/O is active. The activity is always released on completion, failure,
or cancellation and does not block lid-close or manually requested sleep.

JPG thumbnail decoding is shared by the macOS grid, main preview, and local AI
analysis. Duplicate requests are coalesced, decoded images are held in a bounded
memory cache, and the current photo preloads the two neighbors on each side.
Both macOS and Web Remote image queues adapt to the machine but stay capped at
four concurrent decodes (two in Low Power Mode or under thermal pressure). The
phone preloads only four nearby full previews instead of issuing redundant
thumbnail requests.

## Project structure

```text
CR3 Companion Cleaner.xcodeproj/
CR3 Companion Cleaner/
├── CR3CompanionCleanerApp.swift  # SwiftUI app entry point
├── ContentView.swift             # Selection, drag/drop, results and confirmation UI
├── CleanerViewModel.swift        # UI state, cancellation and background operations
├── PhotoScanner.swift            # Recursive CR3/JPG discovery and permission handling
├── BackupCheckService.swift      # Read-only memory-card/backup content verification
├── CleanupService.swift          # Dry Run and FileManager.trashItem cleanup
├── BlurDetection.swift           # Swappable local Core ML adapter and analyzer
├── WebRemoteServer.swift         # PIN-protected LAN phone UI and image previews
├── Models.swift                  # Shared result models
├── Models/                       # Core ML source package, license and swap notes
├── Resources/BlurDetector.mlmodelc
└── CR3 Companion Cleaner.entitlements
CR3 Companion CleanerTests/
└── PhotoScannerTests.swift       # Scanner unit tests
```
