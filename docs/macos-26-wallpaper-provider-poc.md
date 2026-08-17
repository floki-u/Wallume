# macOS 26 wallpaper-provider POC boundary

`WallumeWallpaperPOC` and `wallume-wallpaper-probe` are a read-only preparation
target for the private-framework provider hypothesis recorded in
`macos-26.6-dynamic-lock-screen-revalidation-2026-08-14.md`.

They intentionally do not contain an `AppExtension` entry point, an extension
Info.plist, an ExtensionKit registration, a `WallpaperAgent` connection, a
remote rendering context, or any wallpaper-store code. The only executable
operation is `dlopen` of the private framework followed by runtime class
presence checks.

Run the probe with:

```sh
swift run wallume-wallpaper-probe
```

A compatible result means only that this macOS build contains the framework and
the minimum observed private XPC types. It does not establish that a provider
can be registered, selected, rendered, or distributed. Any future activation
work must stay in a separate, disposable-user or VM POC and must first pass the
P0.5 acceptance matrix.

`WallumeWallpaperProviderPOC` is the next static layer. It compiles a genuine
`AppExtension` conformer and an `AppExtensionConfiguration`, but ships neither
an `@main` entry point nor an extension bundle metadata file. Its configuration
unconditionally rejects every XPC connection. This establishes compile-time
compatibility with ExtensionKit while making activation impossible in the
current development account.

`wallume-wallpaper-provider-fixture` then compiles the same configuration under
an `@main` `AppExtension` lifecycle entry point. It is only a binary build
artifact: it is not an `.appex`, is not embedded in an app bundle, and must not
be run from the shared development account. Creating an `.appex` and asking
ExtensionKit to discover it are explicit future activation steps, not build
side effects.
