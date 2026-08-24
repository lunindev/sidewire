# Packaging — Sidewire Rust Display client (Phase 8 M4)

> **Status: SCAFFOLDING ONLY — NOT YET BUILT OR TESTED ON A TARGET OS.**
> Everything in this directory is a *documented recipe + CI starting point*. It was authored on a
> macOS dev box where the Windows/Linux cross toolchains and the target-OS ffmpeg/wgpu libraries are
> out of reach, so **no Windows `.zip`/MSI or Linux AppImage/`.deb` artifact has actually been
> produced or run**. Treat the commands below as a first draft to validate on real Windows 11 and
> Ubuntu LTS runners; expect to adjust paths and library
> names once a real build surfaces the specifics.

The app is a single self-contained binary (`sidewire-viewer`) plus its **runtime shared libraries**.
There is no installer logic, services, or registry use — packaging is "ship the binary + the libs it
dlopen/dylinks + a launcher entry."

## Runtime dependency situation (read this first — it drives every recipe)

Two runtime dependencies dominate; both are **dynamic** by default:

1. **ffmpeg 7.x — `libavcodec` + `libavutil`** (via the `ffmpeg-the-third` crate, used only by
   `sidewire-media`). The release binary **dynamically links** these. A distributable must therefore
   either:
   - **bundle the shared libs** next to the binary (Windows: `avcodec-61.dll`, `avutil-59.dll`, and
     their transitive deps such as `swresample`; Linux: `libavcodec.so.61`, `libavutil.so.59`, …), or
   - **statically link ffmpeg** (build ffmpeg with `--enable-static --disable-shared` and point the
     crate's `FFMPEG_DIR`/`pkg-config` at it; note the LGPL/GPL implications of what you enable), or
   - **declare a package dependency** on the distro's ffmpeg 7.x runtime (the `.deb` path — see below).

   The exact soname/versions (`61`/`59`) track ffmpeg 7.x; on a real build, read them off the linked
   binary (`ldd` / `dumpbin /dependents` / `otool -L`) rather than trusting this list.

2. **wgpu → a working GPU backend.** wgpu needs a **Vulkan (Linux), D3D12/D3D11 (Windows), or Metal
   (macOS)** capable driver at runtime. This is a *driver on the user's machine*, not something we can
   bundle — document it as a system requirement. For headless/driverless boxes, wgpu can fall back to
   software (e.g. Vulkan-on-`llvmpipe`/`swiftshader`) but the viewer targets a real GPU; a fallback is
   out of scope for M4.

Everything else (`ring`, `rustls`, `winit`, mDNS) is statically linked into the Rust binary.

## Windows

### `.zip` (the baseline — do this first)
1. `cargo build --release` on a Windows runner **with ffmpeg 7.x dev libraries available** to
   `pkg-config`/`FFMPEG_DIR` (e.g. the `shared` build from https://www.gyan.dev/ffmpeg/builds/ or
   vcpkg `ffmpeg[avcodec,avutil]`). Set `FFMPEG_DIR` to the ffmpeg root so the crate's build script
   finds `include/` + `lib/`.
2. Assemble a folder:
   ```
   sidewire-viewer/
     sidewire-viewer.exe
     avcodec-61.dll
     avutil-59.dll
     swresample-5.dll        # + any other DLLs `dumpbin /dependents sidewire-viewer.exe` lists
     README-run.txt          # "needs a D3D12/D3D11-capable GPU driver"
   ```
   Copy the DLLs from the ffmpeg `bin/` used at build time. **Verify** with
   `dumpbin /dependents sidewire-viewer.exe` (or Dependencies.exe) that every non-system DLL is
   present in the folder.
3. `Compress-Archive sidewire-viewer sidewire-viewer-vX.Y.Z-win64.zip`.

### MSI (optional, WiX) — notes only
- Use **WiX Toolset v4** (`wix build`) or `cargo-wix`. A minimal `Product.wxs` installs the `.exe`
  + the bundled DLLs into `Program Files\Sidewire\`, adds a Start-menu shortcut, and (optionally) a
  per-user firewall exception for inbound TCP on the listener port (the Display is a listener —
  Windows Firewall will otherwise prompt on first accept).
- MSI buys you add/remove-programs + upgrade codes; it does **not** solve the DLL bundling — the same
  ffmpeg DLLs must be included as MSI components.
- Code-signing (signtool + an EV/OV cert) is a separate release-hardening step (Phase 9), not M4.

## Linux

### `.desktop` entry
[`sidewire-viewer.desktop`](sidewire-viewer.desktop) is the launcher entry (used by both the AppImage
and the `.deb`). Install it to `/usr/share/applications/` (`.deb`) or embed at the AppDir root
(AppImage). Ship an icon named `sidewire-viewer.(png|svg)` alongside it (a real icon asset is a Phase 9
polish item — the `.desktop` references `sidewire-viewer` by icon name).

### AppImage (linuxdeploy — the portable baseline)
1. `cargo build --release` on an Ubuntu runner with ffmpeg 7.x **dev** packages
   (`libavcodec-dev libavutil-dev`, which on current Ubuntu LTS provide the 7.x soname — verify).
2. Build an AppDir:
   ```
   AppDir/usr/bin/sidewire-viewer
   AppDir/usr/share/applications/sidewire-viewer.desktop
   AppDir/usr/share/icons/hicolor/256x256/apps/sidewire-viewer.png
   ```
3. Run **`linuxdeploy`** with `--appimage` (it walks the binary's `NEEDED` libs and pulls
   `libavcodec.so.61`, `libavutil.so.59`, and their transitive deps into the AppDir). **Do not** bundle
   the Vulkan loader/driver — let it resolve from the host so the user's real GPU driver is used;
   `linuxdeploy` excludes graphics drivers by default, which is what we want.
4. Output: `Sidewire_Viewer-vX.Y.Z-x86_64.AppImage`. Runtime requirement: a Vulkan-capable driver
   (`vulkan-loader` + a Mesa/NVIDIA ICD) on the host.

### `.deb` (distro-native, for apt users)
- Use `cargo-deb`. Instead of bundling ffmpeg, **declare a dependency** on the distro's ffmpeg 7.x
  runtime: `libavcodec61, libavutil59` (confirm the exact package names on the target Ubuntu release —
  they change with ffmpeg major). Add `mesa-vulkan-drivers | vulkan-driver` as a recommended/depends
  for the GPU path.
- `cargo-deb` reads `[package.metadata.deb]` in the crate's `Cargo.toml` (assets = the binary + the
  `.desktop` + icon). That metadata block is **not added yet** (it belongs on a real Linux build where
  the dependency names can be verified) — add it when you first cut a `.deb`.

## What is buildable here vs. what a real cross-build still needs

| Piece | State |
|---|---|
| `.desktop` file | **Written**, valid, ready to install. |
| CI workflow | **Not written.** This repository has no CI. |
| Recipes above | **Documented**, unverified on-target. |
| Windows `.zip` / MSI | **Not built.** Needs a Windows runner + ffmpeg 7.x libs; confirm the exact DLL set via `dumpbin`. |
| Linux AppImage / `.deb` | **Not built.** Needs an Ubuntu runner + ffmpeg 7.x dev libs; confirm sonames via `ldd` and `.deb` dep names on-target. |
| Icon asset | **Missing** (Phase 9 polish). |
| Code-signing / notarization | Out of scope (Phase 9). |

**Bottom line for a real build:** stand up the two runners, get ffmpeg 7.x on each, run
`cargo build --release`, then read the *actual* linked-library set off the binary (`ldd` /
`dumpbin /dependents`) and bundle exactly those — do not trust the illustrative soname list above.
