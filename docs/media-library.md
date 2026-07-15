# Media Library

## Assertion List

- Commands: `import`, `list`, `show`, `remove`
- Source ownership: source files are never modified or deleted
- Duplicate identity: complete source SHA-256
- Owned data: one HEVC `hvc1` `.mov` variant plus thumbnail and cover under Wallume roots
- Failure rule: no half-registered item survives

## Commands

```bash
wallume-media import ~/Movies/source.mov ~/Movies/folder
wallume-media list
wallume-media show 00000000-0000-0000-0000-000000000000
wallume-media remove 00000000-0000-0000-0000-000000000000
```

`import` accepts `.mp4` and `.mov` files, including supported files found under
directories. Results are printed in stable path order. A successful import creates one
owned `.mov` variant encoded as HEVC `hvc1`, capped at a longest edge of 3840 pixels
and a frame rate of 60 fps. It also creates a JPEG thumbnail and cover image.

`list` prints the media ID, display name, and original source path for each indexed item.
`show` prints the stored metadata and owned artifact paths for one item. `remove` deletes
only the registered variant, thumbnail, cover, and index entry for the media ID.

## Exit Codes

- `0`: every requested operation succeeded, or every import result was a duplicate.
- `1`: at least one import result failed or was cancelled.
- `2`: a read, show, remove, or command operational error occurred.
- `64`: the command syntax was invalid.

## Ownership

Wallume never moves, copies into an `Originals` directory, modifies, or deletes imported
source files. The source file's SHA-256 is the duplicate identity. Re-importing identical
bytes returns the existing media item and does not transcode or create new owned files.

The media index is:

```text
~/Library/Application Support/Wallume/Library/library.json
```

Owned media files are:

```text
~/Library/Application Support/Wallume/Library/Variants/<media-id>.mov
~/Library/Caches/app.wallume.Wallume/Thumbnails/<media-id>.jpg
~/Library/Caches/app.wallume.Wallume/Metadata/<media-id>.jpg
~/Library/Caches/app.wallume.Wallume/ImportWork/<transaction-id>/
```

`library.json` is the only media-index authority. Imports stage files under `ImportWork`,
install owned artifacts into their final directories, then register the item as the commit
point. A failed or cancelled import cleans its work directory and leaves no index entry.

`remove` validates that every registered artifact path is a regular file under its
expected Wallume-owned root with no symlinked parent before unlinking anything. Missing
owned artifacts are treated as already removed. Outside paths, symlinks, and non-regular
files are rejected without changing the index.

## Manual Acceptance

Use disposable media files and an isolated `HOME` for acceptance checks:

```bash
export WALLUME_ACCEPT_HOME="$(mktemp -d)"
export WALLUME_ACCEPT_HOME="$(cd "$WALLUME_ACCEPT_HOME" && pwd -P)"
export WALLUME_ACCEPT_CACHE="$WALLUME_ACCEPT_HOME/cache"
shasum -a 256 sample.mp4 sample.mov
HOME="$WALLUME_ACCEPT_HOME" XDG_CACHE_HOME="$WALLUME_ACCEPT_CACHE" \
  .build/release/wallume-media import sample.mp4 sample.mov
HOME="$WALLUME_ACCEPT_HOME" XDG_CACHE_HOME="$WALLUME_ACCEPT_CACHE" \
  .build/release/wallume-media list
```

After import, confirm the source SHA-256 values are unchanged. For every imported item,
open the variant with AVFoundation or another Apple media inspector and verify:

- codec is HEVC `hvc1`;
- container is `.mov`;
- longest edge is at most 3840 pixels;
- frame rate is at most 60 fps.

Then run:

```bash
HOME="$WALLUME_ACCEPT_HOME" XDG_CACHE_HOME="$WALLUME_ACCEPT_CACHE" \
  .build/release/wallume-media remove <media-id>
```

Confirm only Wallume-owned variant, thumbnail, cover, and index data changed. The source
files must remain byte-for-byte identical before and after import and removal.
