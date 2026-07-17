# Media test fixtures

Tiny (~5 KB) Annex-B elementary streams used by `sidewire-media`'s decode tests and the
`sidewire-viewer` end-to-end loopback video test. Each is 320×240, 10 fps, 0.5 s (5 frames),
`yuv420p`, **no B-frames**, GOP 5 (IDR every 5 frames → the single IDR here is frame 0), with
**parameter sets in-band** at the IDR — exactly the stream shape Sidewire puts on the wire
(docs/04-media-pipeline.md, docs/02 § VIDEO).

Regenerate with the ffmpeg **CLI** (v8.x on PATH is fine for *making* bitstreams; decode uses the
linked libavcodec 7.x):

```sh
ffmpeg -y -f lavfi -i testsrc=size=320x240:rate=10 -t 0.5 \
  -c:v libx264 -bf 0 -g 5 -pix_fmt yuv420p -bsf:v h264_mp4toannexb -f h264 clip.h264

ffmpeg -y -f lavfi -i testsrc=size=320x240:rate=10 -t 0.5 \
  -c:v libx265 -bf 0 -g 5 -pix_fmt yuv420p -f hevc clip.h265
```

- `clip.h264` — H.264. NALs: `SPS, PPS, SEI, IDR, P, P, P, P` → 5 access units (AU 0 = keyframe).
- `clip.h265` — HEVC. NALs: `VPS, SPS, PPS, SEI, IDR, P, P, P, P` → 5 access units (AU 0 = keyframe).

Note both 4-byte (`00 00 00 01`) and 3-byte (`00 00 01`) start codes appear; the Annex-B splitter
handles both.
