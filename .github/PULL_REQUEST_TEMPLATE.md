## What and why

<!-- One paragraph. If it closes an issue, "Closes #123". -->

## How it was tested

<!-- There is no CI yet, so this is the only evidence there is. Paste the real output, not "tests
     pass". Say if you ran it on physical hardware — that is the project's largest untested area. -->

```
```

## Checklist

- [ ] Ran the test suite covering what I changed, and pasted the output above:
      `swift test` in `app/Packages/SidewireProtocol` (40) and/or `app/Packages/SidewireCore` (39),
      and/or `cargo test` in `app/clients/sidewire-viewer` (80, +1 ignored).
- [ ] `cargo fmt` on the files I touched, and `cargo clippy --workspace --all-targets` is clean
      *(if I touched Rust — note the tree is not yet fully formatted; do not reformat it wholesale)*.
- [ ] Commit subjects follow Conventional Commits — `scripts/release.mjs` parses them to build the
      changelog, so a non-matching subject is silently dropped.
- [ ] Ticked the corresponding item in `TODO.md` if this PR closes one.
- [ ] No wire-format change — or, if there is one, `app/docs/02-protocol.md` is updated,
      `app/protocol-vectors/` is regenerated deliberately, and both implementations are updated.
      Called out below.
- [ ] No signing material, build output, or generated `Sidewire.xcodeproj` committed; the checked-in
      ad-hoc signing default in `app/project.yml` is untouched.
- [ ] This is not a security fix. *(Security issues go through private reporting first —
      see `SECURITY.md`.)*

## Anything reviewers should look at closely

<!-- Delete if nothing. Concurrency, the pairing path, and anything parsing bytes from a peer
     deserve a flag here. -->
