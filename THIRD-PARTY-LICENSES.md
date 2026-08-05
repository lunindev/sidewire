# Third-party licences

Sidewire itself is MIT (see [`LICENSE`](LICENSE)). This file is the attribution record for
everything Sidewire *does not* own but builds on, links against, or redistributes: the Rust
dependency tree of the `sidewire-viewer` client, the Swift packages the macOS app resolves through
SwiftPM, and — separately and most importantly — the FFmpeg libraries the Rust client links
dynamically. Nothing here is written from memory: the Rust section is generated from
`cargo metadata` against the checked-in `Cargo.lock`, and every Swift licence claim is marked as
either **verified** (a licence file was read on disk at the pinned revision) or **stated**
(taken from the package manifest, not confirmed). Regeneration instructions are in each section,
and the exact commands used to produce this revision are listed at the bottom.

**Last regenerated:** 2026-08-05, from the checked-in `app/clients/sidewire-viewer/Cargo.lock` and
`app/Packages/SidewireCore/Package.resolved` on `main`. Regenerate whenever either of those two
files changes — they are the only inputs that can invalidate §2 and §3.

---

## 1. FFmpeg — read this section first

> **Status: unresolved licensing risk for binary distribution.** It does not block publishing
> source. It does block shipping a compiled `sidewire-viewer`.

The `sidewire-media` crate links FFmpeg 7.x dynamically through `ffmpeg-the-third`. FFmpeg is not
a Rust crate and is not covered by the Cargo licence data below — it is a system library, and
**its licence depends entirely on how that particular FFmpeg was configured at build time.**

### What was actually checked on this machine

`app/README.md:111` tells contributors to `brew install rust ffmpeg@7 pkg-config`. That formula was
inspected directly:

```
$ brew info ffmpeg@7
==> ffmpeg@7: 7.1.5_1 → stable 7.1.5 (bottled) [keg-only]
License: GPL-3.0-or-later
```

```
$ /opt/homebrew/opt/ffmpeg@7/bin/ffmpeg -version
ffmpeg version 7.1.5 Copyright (c) 2000-2026 the FFmpeg developers
configuration: --prefix='/opt/homebrew/Cellar/ffmpeg@7/7.1.5_1' --enable-shared --enable-pthreads
  --enable-version3 ... --enable-gpl --enable-libaom ... --enable-libx264 --enable-libx265 ...
```

Both `--enable-gpl` and `--enable-version3` are present, and Homebrew's own metadata agrees:
**GPL-3.0-or-later**.

The `target/release/sidewire-viewer` binary present in this working tree links seven libraries from
exactly that keg:

```
$ otool -L target/release/sidewire-viewer | grep ffmpeg@7
  /opt/homebrew/opt/ffmpeg@7/lib/libavutil.59.dylib
  /opt/homebrew/opt/ffmpeg@7/lib/libavcodec.61.dylib
  /opt/homebrew/opt/ffmpeg@7/lib/libavformat.61.dylib
  /opt/homebrew/opt/ffmpeg@7/lib/libavdevice.61.dylib
  /opt/homebrew/opt/ffmpeg@7/lib/libavfilter.10.dylib
  /opt/homebrew/opt/ffmpeg@7/lib/libswscale.8.dylib
  /opt/homebrew/opt/ffmpeg@7/lib/libswresample.5.dylib
```

### Why the flags matter, precisely

- FFmpeg's own code is **LGPL-2.1-or-later** by default. Linking against an LGPL build — even
  statically, with caveats — does not impose copyleft on your source.
- `--enable-gpl` permits FFmpeg to compile in GPL-licensed components (x264, x265, several filters).
  The resulting libraries are then distributable only under the **GPL-2.0-or-later**.
- `--enable-version3` upgrades the LGPL-2.1 parts to LGPL-3.0. Combined with `--enable-gpl`, the
  only licence that covers the whole is **GPL-3.0**, which is what Homebrew declares.

Consequences, stated carefully:

- **Publishing Sidewire's source under MIT creates no obligation.** The GPL is a distribution
  licence for the combined work; no combined work is being distributed by publishing a repository
  that merely instructs the reader to install FFmpeg themselves. The MIT claim in the crate
  manifests and on the landing page is accurate *for the source*.
- **Distributing a compiled `sidewire-viewer` linked against a GPL FFmpeg build is a different
  act.** The binary is a combined work, and the GPL-3.0 terms would govern its distribution —
  including the requirement to offer corresponding source for the whole under GPL-compatible terms.
  MIT is GPL-compatible in one direction only: MIT code can be absorbed into a GPL work, not the
  reverse. Shipping such a binary while describing the download as "MIT-licensed" would be wrong.

### The fix is cheap, and it is a build-configuration change, not a code change

Sidewire only decodes. **H.264 and HEVC decoders are native FFmpeg code under LGPL-2.1** — they
need no external library and are unaffected by `--disable-gpl`. (The GPL exposure comes from
*encoders*: x264 and x265. Sidewire's Rust client never encodes; the Mac encodes via
VideoToolbox.) An LGPL-only FFmpeg is therefore fully sufficient:

```
--disable-gpl --disable-nonfree --disable-version3 --enable-decoder=h264,hevc
```

Two further notes for whoever does the packaging:

- **Dynamic linking is the conventional answer** and keeps LGPL compliance simple: ship the
  unmodified `.dylib`/`.so`/`.dll` files, the LGPL text, and a note saying which version they are.
  Static linking triggers LGPL §6, which requires shipping relinkable objects or sources so a user
  can substitute their own FFmpeg. Prefer dynamic.
- The `avdevice`, `avfilter`, `swscale` and `swresample` links in that `otool` output are
  incidental — they came from `ffmpeg-the-third`'s default features, not from anything Sidewire
  calls. That binary predates the current `Cargo.toml`, which now declares
  `default-features = false, features = ["codec", "format", "non-exhaustive-enums"]`; a rebuild
  should link fewer libraries and shrink the surface that needs auditing. Re-run the `otool -L`
  above after the next release build and update this section with what it actually reports.

*Not verified here:* the claim that other distributions' FFmpeg packages are also GPL. Only
Homebrew's `ffmpeg@7` was inspected. Each shipping platform's FFmpeg must be checked on its own
before a binary is published for it.

---

## 2. Rust workspace — `app/clients/sidewire-viewer/`

### How this list was produced

```bash
cd app/clients/sidewire-viewer
cargo metadata --format-version 1 > meta.json
jq -r '[.workspace_members[]] as $ws
       | .packages[] | select(.id as $i | ($ws | index($i)) | not)
       | "\(.license // "NO LICENSE FIELD")\t\(.name)\t\(.version)"' meta.json
```

Run that after any dependency change and replace §2.4 below with its output.

`cargo metadata --offline` fails on a machine whose registry cache is incomplete
(`error: failed to download ab_glyph v0.2.32 — attempting to make an HTTP request, but --offline
was specified`). It resolves entirely from `Cargo.lock` — no version selection happens — but the
`.crate` sources must be present locally. Run it once with network access, or `cargo fetch` first.

### 2.1 Counts

| Figure | Value |
| --- | --- |
| `[[package]]` entries in `Cargo.lock` | **323** |
| Packages reported by `cargo metadata` | **323** |
| First-party workspace members (`sidewire-proto`, `sidewire-crypto`, `sidewire-media`, `sidewire-viewer`) | **4** |
| **Third-party crates requiring attribution** | **319** |
| All third-party crates sourced from `registry+https://github.com/rust-lang/crates.io-index` | 319 / 319 |
| Distinct licence expressions | **26** |
| Crates with a null or missing `license` field | **0** |

Direct (non-path) dependencies declared by the four workspace crates: `bytemuck`,
`ffmpeg-the-third`, `getrandom`, `hex`, `hmac`, `log`, `mdns-sd`, `pem`, `pollster`, `rcgen`,
`rustls`, `rustls-pki-types`, `serde`, `serde_json`, `sha2`, `subtle`, `thiserror`, `wgpu`,
`winit`, `x25519-dalek`, `x509-parser`. Everything else in §2.4 is transitive.

Note that `cargo metadata` with no `--filter-platform` returns the union of **all** target
platforms. The Windows, Android, WebAssembly, Redox and UEFI crates below are in the resolve graph
but are not compiled on macOS or Linux. They are listed anyway: attribution should cover what is
shipped, and the client targets more than one OS.

### 2.2 Everything resolves to a permissive licence

No crate in the graph is GPL, AGPL, MPL, CDDL or EPL under any choice of terms. **Two findings are
worth a second look, and neither is a blocker:**

- **`r-efi 5.3.0` and `r-efi 6.0.0` — `MIT OR Apache-2.0 OR LGPL-2.1-or-later`.** This is the only
  appearance of the letters "LGPL" in the whole tree. It is a triple-**OR**, so MIT can simply be
  taken, and in any case the crate is unreachable for Sidewire's targets — `cargo metadata` shows
  it gated behind `cfg(all(target_os = "uefi", getrandom_backend = "efi_rng"))` under `getrandom`.
  No action needed; noted so nobody rediscovers it in a panic later.
- **`hexf-parse 0.2.1` — `CC0-1.0`.** A public-domain dedication. Permissive in effect, but some
  corporate policies flag CC0 because its patent language differs from a normal software licence.
  Fine for this project; flagged for completeness.

Two more that are unusual but harmless:

- **`ffmpeg-the-third 3.0.2` and `ffmpeg-sys-the-third 3.0.1` — `WTFPL`.** This is the licence of
  the *Rust bindings*, and it is maximally permissive. It says nothing about the FFmpeg libraries
  those bindings load — see §1, which is the part that actually matters.
- **23 crates use the deprecated slash syntax** (`MIT/Apache-2.0`, `Apache-2.0/MIT`,
  `Unlicense/MIT`) rather than SPDX `OR`. Cargo treats `/` as `OR`; the groups are kept separate
  below because that is verbatim what the manifests declare.

### 2.3 `ring 0.17.14` — verified, and the notice obligation is real

The `license` field says `Apache-2.0 AND ISC`. Unlike most crates this `AND` is not a formatting
slip — `ring` genuinely is a mixture, and its own `LICENSE` file (read from the local registry
checkout at `~/.cargo/registry/src/index.crates.io-*/ring-0.17.14/LICENSE`) explains it:

> *ring* uses an "ISC" license, like BoringSSL used to use, for new code files. See
> LICENSE-other-bits for the text of that license. See LICENSE-BoringSSL for code that was sourced
> from BoringSSL under the Apache 2.0 license. Some code that was sourced from BoringSSL under the
> ISC license. In each case, the license info is at the top of the file.

The crate ships three licence files, all verified present:

| File | Contents |
| --- | --- |
| `LICENSE` | The explanation quoted above, plus a pointer to `src/polyfill/once_cell/LICENSE-{APACHE,MIT}`. |
| `LICENSE-BoringSSL` | The full Apache License 2.0 text, covering BoringSSL-derived code. |
| `LICENSE-other-bits` | An ISC-style permissive licence, "Copyright 2015-2025 Brian Smith." |

Practical consequence: `ring` cannot be reduced to a single-line "MIT" entry, and both the Apache
2.0 and ISC notices must travel with any binary that contains it. `ring` is not optional here —
`rustls` and `rcgen` are both configured onto the `ring` backend in
`app/clients/sidewire-viewer/Cargo.toml`, so it is in every build.

**Apache-2.0 is mandatory (not one option among several) for 14 crates**, and each of these carries
the Apache §4(d) obligation to propagate any `NOTICE` file into redistributed binaries:

`ab_glyph 0.2.32`, `ab_glyph_rasterizer 0.1.10`, `clang 2.0.0`, `clang-sys 1.8.1`,
`codespan-reporting 0.11.1`, `dpi 0.1.2` (`Apache-2.0 AND MIT` — both, not either),
`gethostname 1.1.0`, `gl_generator 0.14.0`, `glutin_wgl_sys 0.6.1`, `khronos_api 3.1.0`,
`owned_ttf_parser 0.25.1`, `ring 0.17.14` (`Apache-2.0 AND ISC`),
`spirv 0.3.0+sdk-1.3.268.0`, `winit 0.30.13`.

For every other crate offering `MIT OR Apache-2.0`, MIT may be elected, which avoids the NOTICE
requirement entirely.

### 2.4 All 319 third-party crates, grouped by declared licence expression

Verbatim from the `license` field of each package's manifest.

#### MIT OR Apache-2.0  — 158 crates

`ahash 0.8.12`, `android-activity 0.6.1`, `arrayvec 0.7.8`, `as-raw-xcb-connection 1.0.1`, `ash 0.38.0+1.3.281`, `asn1-rs 0.6.2`, `asn1-rs-derive 0.5.1`, `base64 0.22.1`, `bitflags 2.13.0`, `block-buffer 0.10.4`, `bumpalo 3.20.3`, `cc 1.2.67`, `cfg-if 1.0.4`, `core-foundation 0.9.4`, `core-foundation-sys 0.8.7`, `core-graphics 0.23.2`, `core-graphics-types 0.1.3`, `cpufeatures 0.2.17`, `crossbeam-utils 0.8.22`, `crypto-common 0.1.7`, `deranged 0.5.8`, `digest 0.10.7`, `displaydoc 0.2.6`, `document-features 0.2.12`, `either 1.16.0`, `errno 0.3.14`, `find-msvc-tools 0.1.9`, `futures-core 0.3.32`, `futures-sink 0.3.32`, `futures-task 0.3.32`, `futures-util 0.3.32`, `getrandom 0.2.17`, `getrandom 0.3.4`, `getrandom 0.4.3`, `glob 0.3.3`, `gpu-alloc 0.6.2`, `gpu-alloc-types 0.3.1`, `gpu-allocator 0.27.0`, `gpu-descriptor 0.3.2`, `gpu-descriptor-types 0.2.0`, `hashbrown 0.15.5`, `hashbrown 0.17.1`, `heck 0.5.0`, `hermit-abi 0.5.2`, `hex 0.4.3`, `hmac 0.12.1`, `itertools 0.12.1`, `itoa 1.0.18`, `jni 0.22.4`, `jni-macros 0.22.4`, `jni-sys 0.3.1`, `jni-sys 0.4.1`, `jni-sys-macros 0.4.1`, `jobserver 0.1.35`, `js-sys 0.3.103`, `lazy_static 1.5.0`, `libc 0.2.186`, `litrs 1.0.0`, `lock_api 0.4.14`, `log 0.4.33`, `memmap2 0.9.11`, `metal 0.31.0`, `naga 24.0.0`, `ndk 0.9.0`, `ndk-context 0.1.1`, `ndk-sys 0.5.0+25.2.9519653`, `ndk-sys 0.6.0+11769913`, `num-bigint 0.4.8`, `num-conv 0.2.2`, `num-integer 0.1.46`, `num-traits 0.2.19`, `oid-registry 0.7.1`, `once_cell 1.21.4`, `parking_lot 0.12.5`, `parking_lot_core 0.9.12`, `paste 1.0.15`, `percent-encoding 2.3.2`, `pkg-config 0.3.33`, `powerfmt 0.2.0`, `presser 0.3.1`, `proc-macro-crate 3.5.0`, `proc-macro2 1.0.106`, `profiling 1.0.18`, `quote 1.0.46`, `rand_core 0.6.4`, `range-alloc 0.1.5`, `rcgen 0.13.2`, `regex 1.13.0`, `regex-automata 0.4.15`, `regex-syntax 0.8.11`, `renderdoc-sys 1.1.0`, `rustc_version 0.4.1`, `rustls-pki-types 1.15.0`, `rustversion 1.0.23`, `scopeguard 1.2.0`, `semver 1.0.28`, `serde 1.0.228`, `serde_core 1.0.228`, `serde_derive 1.0.228`, `serde_json 1.0.150`, `sha2 0.10.9`, `shlex 1.3.0`, `shlex 2.0.1`, `simdutf8 0.1.5`, `smallvec 1.15.2`, `smol_str 0.2.2`, `socket2 0.5.10`, `static_assertions 1.1.0`, `syn 2.0.118`, `thiserror 1.0.69`, `thiserror 2.0.18`, `thiserror-impl 1.0.69`, `thiserror-impl 2.0.18`, `time 0.3.53`, `time-core 0.1.9`, `time-macros 0.2.31`, `toml_datetime 1.1.1+spec-1.1.0`, `toml_edit 0.25.12+spec-1.1.0`, `toml_parser 1.1.2+spec-1.1.0`, `ttf-parser 0.25.1`, `typenum 1.20.1`, `unicode-segmentation 1.13.3`, `unicode-width 0.1.14`, `unicode-xid 0.2.6`, `wasm-bindgen 0.2.126`, `wasm-bindgen-futures 0.4.76`, `wasm-bindgen-macro 0.2.126`, `wasm-bindgen-macro-support 0.2.126`, `wasm-bindgen-shared 0.2.126`, `web-sys 0.3.103`, `web-time 1.1.0`, `wgpu 24.0.5`, `wgpu-core 24.0.5`, `wgpu-hal 24.0.4`, `wgpu-types 24.0.0`, `windows 0.58.0`, `windows-core 0.58.0`, `windows-implement 0.58.0`, `windows-interface 0.58.0`, `windows-link 0.2.1`, `windows-result 0.2.0`, `windows-strings 0.1.0`, `windows-sys 0.52.0`, `windows-sys 0.59.0`, `windows-sys 0.61.2`, `windows-targets 0.52.6`, `windows_aarch64_gnullvm 0.52.6`, `windows_aarch64_msvc 0.52.6`, `windows_i686_gnu 0.52.6`, `windows_i686_gnullvm 0.52.6`, `windows_i686_msvc 0.52.6`, `windows_x86_64_gnu 0.52.6`, `windows_x86_64_gnullvm 0.52.6`, `windows_x86_64_msvc 0.52.6`, `x11rb 0.13.2`, `x11rb-protocol 0.13.2`, `x509-parser 0.16.0`, `yasna 0.5.2`

#### MIT  — 66 crates

`android-properties 0.2.2`, `block 0.1.6`, `block2 0.5.1`, `bytes 1.12.1`, `calloop 0.13.0`, `calloop-wayland-source 0.3.0`, `cfg_aliases 0.2.1`, `combine 4.6.7`, `data-encoding 2.11.0`, `dispatch 0.2.0`, `dlib 0.5.3`, `generic-array 0.14.7`, `libredox 0.1.18`, `malloc_buf 0.0.6`, `mio 1.2.1`, `nom 7.1.3`, `objc 0.2.7`, `objc-sys 0.3.5`, `objc2 0.5.2`, `objc2-app-kit 0.2.2`, `objc2-cloud-kit 0.2.2`, `objc2-contacts 0.2.2`, `objc2-core-data 0.2.2`, `objc2-core-image 0.2.2`, `objc2-core-location 0.2.2`, `objc2-encode 4.1.0`, `objc2-foundation 0.2.2`, `objc2-link-presentation 0.2.2`, `objc2-metal 0.2.2`, `objc2-quartz-core 0.2.2`, `objc2-symbols 0.2.2`, `objc2-ui-kit 0.2.2`, `objc2-uniform-type-identifiers 0.2.2`, `objc2-user-notifications 0.2.2`, `orbclient 0.3.55`, `ordered-float 4.6.0`, `pem 3.0.6`, `quick-xml 0.39.4`, `redox_syscall 0.4.1`, `redox_syscall 0.5.18`, `redox_syscall 0.9.0`, `sctk-adwaita 0.10.1`, `slab 0.4.12`, `smithay-client-toolkit 0.19.2`, `spin 0.9.8`, `strict-num 0.1.1`, `strum 0.26.3`, `strum_macros 0.26.4`, `synstructure 0.13.2`, `tracing 0.1.44`, `tracing-core 0.1.36`, `wayland-backend 0.3.15`, `wayland-client 0.31.14`, `wayland-csd-frame 0.3.0`, `wayland-cursor 0.31.14`, `wayland-protocols 0.32.13`, `wayland-protocols-plasma 0.3.12`, `wayland-protocols-wlr 0.3.12`, `wayland-scanner 0.31.10`, `wayland-sys 0.31.11`, `winnow 1.0.3`, `x11-dl 2.21.0`, `xcursor 0.3.10`, `xkbcommon-dl 0.4.2`, `xml-rs 0.8.28`, `zmij 1.0.21`

#### MIT/Apache-2.0  — 17 crates

`android_system_properties 0.1.5`, `asn1-rs-impl 0.2.0`, `bitflags 1.3.2`, `curve25519-dalek-derive 0.1.1`, `der-parser 9.0.0`, `downcast-rs 1.2.1`, `foreign-types 0.5.0`, `foreign-types-macros 0.2.3`, `foreign-types-shared 0.3.1`, `khronos-egl 6.0.0`, `lazycell 1.3.0`, `minimal-lexical 0.2.1`, `plain 0.2.3`, `rusticata-macros 4.1.0`, `scoped-tls 1.0.1`, `vcpkg 0.2.15`, `version_check 0.9.5`

#### Apache-2.0 OR MIT  — 16 crates

`atomic-waker 1.1.2`, `autocfg 1.5.1`, `bit-set 0.8.0`, `bit-vec 0.8.0`, `concurrent-queue 2.5.0`, `equivalent 1.0.2`, `fastrand 2.4.1`, `indexmap 2.14.0`, `mdns-sd 0.13.11`, `pin-project 1.1.13`, `pin-project-internal 1.1.13`, `pin-project-lite 0.2.17`, `polling 3.11.0`, `simd_cesu8 1.1.1`, `zeroize 1.9.0`, `zeroize_derive 1.5.0`

#### Apache-2.0  — 12 crates

`ab_glyph 0.2.32`, `ab_glyph_rasterizer 0.1.10`, `clang 2.0.0`, `clang-sys 1.8.1`, `codespan-reporting 0.11.1`, `gethostname 1.1.0`, `gl_generator 0.14.0`, `glutin_wgl_sys 0.6.1`, `khronos_api 3.1.0`, `owned_ttf_parser 0.25.1`, `spirv 0.3.0+sdk-1.3.268.0`, `winit 0.30.13`

#### Apache-2.0 WITH LLVM-exception OR Apache-2.0 OR MIT  — 7 crates

`linux-raw-sys 0.12.1`, `linux-raw-sys 0.4.15`, `rustix 0.38.44`, `rustix 1.1.4`, `wasi 0.11.1+wasi-snapshot-preview1`, `wasip2 1.0.4+wasi-0.2.12`, `wit-bindgen 0.57.1`

#### BSD-3-Clause  — 6 crates

`bindgen 0.69.5`, `curve25519-dalek 4.1.3`, `subtle 2.6.1`, `tiny-skia 0.11.4`, `tiny-skia-path 0.11.4`, `x25519-dalek 2.0.1`

#### Apache-2.0/MIT  — 4 crates

`cexpr 0.6.0`, `flume 0.11.1`, `pollster 0.4.0`, `rustc-hash 1.1.0`

#### MIT OR Apache-2.0 OR Zlib  — 4 crates

`cursor-icon 1.2.0`, `glow 0.16.0`, `raw-window-handle 0.6.2`, `xkeysym 0.2.1`

#### Unlicense OR MIT  — 4 crates

`aho-corasick 1.1.4`, `memchr 2.8.3`, `termcolor 1.4.1`, `winapi-util 0.1.11`

#### ISC  — 3 crates

`libloading 0.8.9`, `rustls-webpki 0.103.13`, `untrusted 0.9.0`

#### BSD-2-Clause OR Apache-2.0 OR MIT  — 2 crates

`zerocopy 0.8.54`, `zerocopy-derive 0.8.54`

#### BSD-3-Clause OR MIT OR Apache-2.0  — 2 crates

`num_enum 0.7.6`, `num_enum_derive 0.7.6`

#### MIT OR Apache-2.0 OR LGPL-2.1-or-later  — 2 crates

`r-efi 5.3.0`, `r-efi 6.0.0`

#### Unlicense/MIT  — 2 crates

`same-file 1.0.6`, `walkdir 2.5.0`

#### WTFPL  — 2 crates

`ffmpeg-sys-the-third 3.0.1+ffmpeg-7.1`, `ffmpeg-the-third 3.0.2+ffmpeg-7.1`

#### Zlib  — 2 crates

`foldhash 0.1.5`, `slotmap 1.1.1`

#### Zlib OR Apache-2.0 OR MIT  — 2 crates

`bytemuck 1.25.1`, `bytemuck_derive 1.11.0`

#### (MIT OR Apache-2.0) AND Unicode-3.0  — 1 crate

`unicode-ident 1.0.24`

#### Apache-2.0 AND ISC  — 1 crate

`ring 0.17.14`

#### Apache-2.0 AND MIT  — 1 crate

`dpi 0.1.2`

#### Apache-2.0 OR ISC OR MIT  — 1 crate

`rustls 0.23.41`

#### BSD-2-Clause  — 1 crate

`arrayref 0.3.9`

#### CC0-1.0  — 1 crate

`hexf-parse 0.2.1`

#### MIT OR Apache-2.0 OR BSD-1-Clause  — 1 crate

`fiat-crypto 0.2.9`

#### MIT OR BSD-3-Clause  — 1 crate

`if-addrs 0.13.4`

---

## 3. Swift packages — macOS app

Two manifests pin these: `app/Packages/SidewireCore/Package.resolved` (the three Apple packages,
plus a stale `sparkle` entry that does not belong to that package's graph) and `app/project.yml`,
which declares Sparkle for the app target.

Unlike Cargo there is no `cargo metadata` equivalent, so this table is maintained by hand.
Regenerate by re-reading `Package.resolved` after `swift package resolve`, and re-reading the
licence files from `app/Packages/SidewireCore/.build/checkouts/<package>/`.

| Package | Version | Revision | Licence | Verified? | Project URL |
| --- | --- | --- | --- | --- | --- |
| Sparkle | 2.9.4 | `b6496a74a087257ef5e6da1c5b29a447a60f5bd7` | MIT | **Verified** — `LICENSE` read at the pinned revision | https://github.com/sparkle-project/Sparkle |
| swift-asn1 | 1.7.1 | `a9a5efd40eaf558a2bcd48d64b1d1646be686008` | Apache-2.0 | **Verified** — `LICENSE.txt` + `NOTICE.txt` read from the local SPM checkout | https://github.com/apple/swift-asn1 |
| swift-certificates | 1.19.3 | `89fbc3714264cce8db8e4ec51b64e01c3e28c6c5` | Apache-2.0 | **Verified** — `LICENSE.txt` + `NOTICE.txt` read from the local SPM checkout | https://github.com/apple/swift-certificates |
| swift-crypto | 3.15.1 | `95ba0316a9b733e92bb6b071255ff46263bbe7dc` | Apache-2.0 | **Verified** — `LICENSE.txt` + `NOTICE.txt` read from the local SPM checkout | https://github.com/apple/swift-crypto |

"Verified" above means the licence file itself was opened on disk at the pinned revision — for the
three Apple packages from `app/Packages/SidewireCore/.build/checkouts/`, and for Sparkle from the
SwiftPM repository cache via `git cat-file -p` at revision `b6496a7`. Nothing in this table is
taken from a manifest field alone.

### 3.1 The Apache-2.0 packages carry a NOTICE obligation

All three Apple packages ship a `NOTICE.txt` alongside the Apache-2.0 licence text. Apache-2.0
§4(d) requires that those notices be carried into redistributed derivative works — which the signed,
notarized Sidewire `.app` is, since it embeds these libraries. Practically: the DMG (or an
in-app acknowledgements screen) should include the Apache-2.0 text and reproduce these notices.
Their upstream attributions are:

- **SwiftASN1** — Copyright 2022 The SwiftASN1 Project. Contains derivations of scripts from
  [SwiftNIO](https://github.com/apple/swift-nio) and
  [Swift OpenAPI Generator](https://github.com/apple/swift-openapi-generator), both Apache-2.0.
- **SwiftCertificates** — Copyright 2022 The SwiftCertificates Project. Contains derivations from
  SwiftNIO and SwiftASN1 (Apache-2.0), test data derived from
  [webpki](https://github.com/briansmith/webpki) (ISC), and test vectors from
  [pyca/cryptography](https://github.com/pyca/cryptography) (Apache-2.0).
- **SwiftCrypto** — Copyright 2019 The SwiftCrypto Project. Contains test vectors from Google's
  [wycheproof](https://github.com/C2SP/wycheproof) (Apache-2.0) and derivations from SwiftNIO
  (Apache-2.0).

**swift-crypto additionally vendors BoringSSL**, as `Sources/CCryptoBoringSSL` — confirmed present
in the checkout, along with `Sources/CCryptoBoringSSL/third_party/fiat`. Its source headers carry
OpenSSL Project copyright under Apache-2.0, e.g. `crypto/mem.cc`:

> `// Copyright 1995-2016 The OpenSSL Project Authors. All Rights Reserved.`
> `// Licensed under the Apache License, Version 2.0 (the "License");`

This is a substantial body of third-party C that ships inside the app binary. It is covered by the
same Apache-2.0 obligation as the Swift code around it.

### 3.2 Sparkle is MIT, but not only MIT

Sparkle's `LICENSE` at the pinned revision is MIT — copyright 2006-2013 Andy Matuschak, 2009-2013
Elgato Systems GmbH, 2011-2014 Kornel Lesiński, 2015-2017 Mayur Pawashe, 2014 C.W. Betts, 2014
Petroules Corporation, 2014 Big Nerd Ranch — followed by an `EXTERNAL LICENSES` section covering
components Sparkle embeds and ships inside the app (the `Vendor/` tree at that revision holds
`bsdiff` and `ed25519-sparkle`):

| Embedded component | Origin | Terms |
| --- | --- | --- |
| `bspatch.c`, `bsdiff.c` | bsdiff 4.3, http://www.daemonology.net/bsdiff/ | BSD-2-Clause, Copyright 2003-2005 Colin Percival |
| `sais.c`, `sais.h` | sais-lite (2010/08/07) | MIT, Copyright 2008-2010 Yuta Mori |
| Portable C Ed25519 | https://github.com/orlp/ed25519 | Zlib-style, Copyright 2015 Orson Peters |
| `SUSignatureVerifier.m` | — | BSD-2-Clause, Copyright 2011 Mark Hamlin |

All four are permissive and all four require their notices to travel with the binary. Reproducing
Sparkle's `LICENSE` file verbatim in the app's acknowledgements satisfies every one of them at once.

### 3.3 Known gaps in this section

- `app/project.yml:59` declares Sparkle as `from: 2.0.0` — an open upper bound. The version above
  (2.9.4) is what `Package.resolved` records **today**; a future resolve could ship a different
  version with different embedded components, and this file would silently go stale. Pinning
  Sparkle to an exact version would make this table trustworthy over time.
- `app/Packages/SidewireProtocol` has its own manifest and was not part of the pin set above;
  it declares no external package dependencies.

---

## 4. Recommended CI gate

Nothing currently prevents a new transitive dependency from introducing GPL, AGPL or an
unrecognised licence. Add [`cargo-deny`](https://github.com/EmbarkStudios/cargo-deny) to the Rust
job in `.github/workflows/ci.yml` (the workflow is still to be written — see `TODO.md` P0) so the
build fails on the pull request that introduces the problem rather than on release day:

```yaml
      - name: Licence audit
        run: |
          cargo install --locked cargo-deny
          cargo deny --manifest-path app/clients/sidewire-viewer/Cargo.toml check licenses
```

A starting `deny.toml` matching the tree as it stands today:

```toml
[licenses]
version = 2
# Every licence that currently appears in the resolve graph, and nothing more.
allow = [
    "MIT", "Apache-2.0", "ISC", "BSD-2-Clause", "BSD-3-Clause", "BSD-1-Clause",
    "Zlib", "Unlicense", "WTFPL", "CC0-1.0", "Unicode-3.0",
    "Apache-2.0 WITH LLVM-exception",
]
confidence-threshold = 0.9

# ring is Apache-2.0 AND ISC with BoringSSL-derived portions; both notices must be retained.
[[licenses.clarify]]
crate = "ring"
expression = "Apache-2.0 AND ISC"
license-files = [{ path = "LICENSE", hash = 0 }]
```

Deliberately *not* allowed: any GPL, AGPL, LGPL, MPL, CDDL or EPL variant. `r-efi`'s
`LGPL-2.1-or-later` option is satisfied by the `MIT` alternative in the same expression, so an
allow-list without LGPL still passes.

Two caveats before wiring it up:

- Fix the `hash = 0` placeholder in the `clarify` block — run `cargo deny check licenses` once and
  paste in the hash it reports, or the clarification will not apply.
- `cargo-deny` was **not** run while producing this file; it is not installed on the machine this
  was generated on (`cargo deny --version` → `error: no such command: 'deny'`). The `deny.toml`
  above is derived from the `cargo metadata` output in §2, not from a `cargo-deny` run, so expect
  to iterate on it the first time.

**`cargo-deny` will not catch the FFmpeg problem.** FFmpeg is a system library, invisible to Cargo.
Guarding that needs a separate packaging-time check — assert on the FFmpeg build's
`avutil_license()` / configuration string, or pin the packaged build to one whose configuration is
under Sidewire's control.

---

## 5. What this file does not cover

- The macOS app's system frameworks (AppKit, CoreGraphics, Network, …). Apple SDK, no attribution
  required.
- Build-time-only tooling that never reaches a shipped artifact: XcodeGen, Node/pnpm dev
  dependencies, the Astro toolchain under `landing/`. The landing site's own runtime dependency set
  should get the same treatment before it is deployed; it is out of scope here.
- Rust crates that are in the resolve graph for platforms Sidewire does not ship. They are listed
  in §2.4 for completeness, but a per-target `cargo metadata --filter-platform` run gives a tighter
  list for each shipped binary.

---

## Appendix — exact commands run to produce this revision

```bash
# Rust dependency data (2026-08-05)
cd app/clients/sidewire-viewer
cargo metadata --format-version 1 --offline   # FAILED: registry cache incomplete
cargo metadata --format-version 1             # succeeded, 1,564,045 bytes of JSON
grep -c '^\[\[package\]\]' Cargo.lock         # 323
jq '.packages | length'                       # 323
jq -r '.packages[] | select(.source != null) | .license' | sort | uniq -c   # the §2.4 grouping

# FFmpeg
brew info ffmpeg@7
/opt/homebrew/opt/ffmpeg@7/bin/ffmpeg -version
otool -L app/clients/sidewire-viewer/target/release/sidewire-viewer

# Swift licence verification
cat app/Packages/SidewireCore/Package.resolved
cat app/Packages/SidewireCore/.build/checkouts/{swift-asn1,swift-certificates,swift-crypto}/{LICENSE.txt,NOTICE.txt}
git -C ~/Library/Caches/org.swift.swiftpm/repositories/Sparkle-09d89c53 \
    cat-file -p b6496a74a087257ef5e6da1c5b29a447a60f5bd7^{tree}   # then the LICENSE blob

# ring
cat ~/.cargo/registry/src/index.crates.io-*/ring-0.17.14/{LICENSE,LICENSE-BoringSSL,LICENSE-other-bits}
```

Toolchain: `cargo 1.97.1 (c980f4866 2026-06-30)`, `rustc 1.97.1 (8bab26f4f 2026-07-14)`.
