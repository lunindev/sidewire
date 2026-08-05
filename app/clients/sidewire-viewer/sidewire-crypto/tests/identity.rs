//! Device-identity tests: `device_id` = first16(SHA256(SPKI)) hex; a freshly generated leaf cert
//! round-trips to the same `spki_hash` when re-parsed via `x509-parser`; and — for Rust↔Swift
//! interop confidence — an OpenSSL cross-check of the SPKI SHA-256 (skipped with a note if the
//! `openssl` binary is unavailable).

use sidewire_crypto::{device_id_from_spki_hash, spki_hash_from_cert_der, Identity};

#[test]
fn device_id_is_first16_of_spki_hash_hex() {
    // A known hash pattern → deterministic id (mirrors PairingTests.testDeviceId...).
    let bytes: Vec<u8> = (0u8..32).collect();
    let id = device_id_from_spki_hash(&bytes);
    assert_eq!(id, "000102030405060708090a0b0c0d0e0f");
    assert_eq!(id.len(), 32);
}

#[test]
fn generated_identity_spki_and_device_id_are_consistent() {
    let id = Identity::generate().expect("generate identity");

    // device_id is 32 hex chars = first 16 bytes of spki_hash.
    assert_eq!(id.device_id.len(), 32);
    assert_eq!(id.device_id, device_id_from_spki_hash(&id.spki_hash));

    // Re-parsing our own leaf cert's SPKI must reproduce the identical spki_hash.
    let from_cert = spki_hash_from_cert_der(&id.cert_der).expect("extract SPKI from leaf");
    assert_eq!(
        from_cert, id.spki_hash,
        "SPKI hash from the cert leaf must match the hash of the public-key DER"
    );

    // The P-256 SPKI is the standard 91-byte SubjectPublicKeyInfo.
    assert_eq!(id.spki_der.len(), 91, "P-256 SPKI is 91 bytes");
}

#[test]
fn identity_pem_roundtrip() {
    let id = Identity::generate().expect("generate");
    let reloaded = Identity::from_pem(&id.cert_pem, &id.key_pem).expect("reload from PEM");
    assert_eq!(reloaded.spki_hash, id.spki_hash);
    assert_eq!(reloaded.device_id, id.device_id);
    assert_eq!(reloaded.cert_der, id.cert_der);
}

/// Cross-check the SPKI SHA-256 against OpenSSL to raise confidence in Swift interop (swift-crypto
/// `derRepresentation` == OpenSSL `i2d_PUBKEY`). Skipped (not failed) if `openssl` is absent, fails
/// to run, or prints a digest in a format we cannot parse — the point is to catch a *mismatch*, so
/// an unusable tool must never be reported as a cross-check failure.
#[test]
fn openssl_cross_check_spki_hash() {
    use std::io::Write;
    use std::process::Command;

    let id = Identity::generate().expect("generate");

    // Write the leaf cert DER to a temp file.
    let dir = std::env::temp_dir();
    let cert_path = dir.join(format!("sidewire-idtest-{}.der", std::process::id()));
    {
        let mut f = match std::fs::File::create(&cert_path) {
            Ok(f) => f,
            Err(e) => {
                eprintln!("skipping openssl cross-check: cannot write temp file: {e}");
                return;
            }
        };
        f.write_all(&id.cert_der).expect("write cert der");
    }

    // openssl x509 -inform DER -in <cert> -pubkey -noout | openssl pkey -pubin -outform DER \
    //   | openssl dgst -sha256
    let pubkey_pem = Command::new("openssl")
        .args(["x509", "-inform", "DER", "-in"])
        .arg(&cert_path)
        .args(["-pubkey", "-noout"])
        .output();
    let pubkey_pem = match pubkey_pem {
        Ok(o) if o.status.success() => o.stdout,
        Ok(o) => {
            eprintln!(
                "skipping openssl cross-check: `openssl x509` failed: {}",
                String::from_utf8_lossy(&o.stderr)
            );
            let _ = std::fs::remove_file(&cert_path);
            return;
        }
        Err(e) => {
            eprintln!("skipping openssl cross-check: openssl not found ({e})");
            let _ = std::fs::remove_file(&cert_path);
            return;
        }
    };
    let _ = std::fs::remove_file(&cert_path);

    // Feed the PEM public key back through openssl to DER, then SHA-256 it.
    let pubkey_der = run_piped(
        "openssl",
        &["pkey", "-pubin", "-outform", "DER"],
        &pubkey_pem,
    )
    .expect("openssl pkey");
    let digest_out = run_piped("openssl", &["dgst", "-sha256"], &pubkey_der).expect("openssl dgst");
    let digest_str = String::from_utf8_lossy(&digest_out);
    // Output format varies by implementation: OpenSSL prints "SHA2-256(stdin)= <hex>" (older
    // builds "(stdin)= <hex>"), while LibreSSL — which is what /usr/bin/openssl is on macOS —
    // prints the bare hex with no prefix at all. Splitting on '=' therefore yields nothing on
    // LibreSSL, so take the last whitespace-separated token and validate it instead.
    let openssl_hex = digest_str
        .split_whitespace()
        .last()
        .unwrap_or("")
        .to_string();
    let looks_like_sha256 =
        openssl_hex.len() == 64 && openssl_hex.bytes().all(|b| b.is_ascii_hexdigit());
    if !looks_like_sha256 {
        // A genuine skip, matching this test's documented contract. Asserting here would turn an
        // unrecognised output format into a spurious failure — which is exactly what used to
        // happen under LibreSSL.
        eprintln!("skipping openssl cross-check: could not parse a SHA-256 out of {digest_str:?}");
        return;
    }

    let ours: String = id.spki_hash.iter().map(|b| format!("{b:02x}")).collect();
    assert_eq!(
        openssl_hex, ours,
        "OpenSSL SPKI SHA-256 must match our spki_hash (Swift interop)"
    );
    eprintln!("openssl cross-check OK: {ours}");
}

/// Run a command feeding `input` on stdin and returning stdout.
fn run_piped(cmd: &str, args: &[&str], input: &[u8]) -> Option<Vec<u8>> {
    use std::io::Write;
    use std::process::{Command, Stdio};
    let mut child = Command::new(cmd)
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .ok()?;
    child.stdin.take()?.write_all(input).ok()?;
    let out = child.wait_with_output().ok()?;
    if out.status.success() {
        Some(out.stdout)
    } else {
        None
    }
}
