#!/usr/bin/env bash
#
# Create a persistent, self-signed code-signing identity for mTerm.
#
#   scripts/create-signing-cert.sh
#
# Run this ONCE per machine, before your first signed release.
#
# Why this exists
# ---------------
# Ad-hoc signing (`codesign -s -`) gives every build a *different* code
# identity (a fresh cdhash). macOS TCC ties permission grants — Accessibility,
# Full Disk Access, the folders you approve — to the app's designated
# requirement, which for an ad-hoc app is that exact cdhash. So every mTerm
# update looks like a brand-new app and macOS re-prompts for every permission.
#
# A stable self-signed identity makes the designated requirement constant across
# builds — `identifier "com.luanzt.mterm" and certificate leaf = H"<fixed>"` —
# so grants persist through updates. No Apple Developer account, trust settings,
# or notarization are required: TCC matches the designated requirement, not the
# certificate's trust chain, and mTerm is installed via right-click ▸ Open.
#
# After running this once, `scripts/package.sh` picks up the identity
# automatically. Override the name with MTERM_SIGN_IDENTITY if you prefer.
set -euo pipefail

IDENTITY="${MTERM_SIGN_IDENTITY:-mTerm Self-Signed}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# Homebrew's OpenSSL 3 writes PKCS#12 archives that macOS `security import`
# cannot read (MAC verification failure); the system LibreSSL is compatible.
OPENSSL="/usr/bin/openssl"

authorize_key() {
    # Let codesign use the private key without a GUI prompt on every build.
    # Requires the keychain password. If skipped, codesign prompts once on the
    # first build; click "Always Allow".
    echo "==> Authorizing codesign to use the key without prompting each build"
    printf '    Enter your login keychain password (leave empty to skip): '
    local pw
    read -rs pw || true
    echo
    if [ -z "$pw" ]; then
        echo "    Skipped. codesign will prompt once on the first build —"
        echo "    click 'Always Allow'."
        return 0
    fi
    if security set-key-partition-list -S apple-tool:,apple:,codesign: \
            -k "$pw" "$KEYCHAIN" >/dev/null 2>&1; then
        echo "    Done."
    else
        echo "    Could not preauthorize (wrong password?). codesign will prompt"
        echo "    once on the first build — click 'Always Allow'."
    fi
}

# Idempotent: reuse an existing identity of the same name.
if security find-identity -p codesigning 2>/dev/null | grep -qF "$IDENTITY"; then
    echo "Code-signing identity '$IDENTITY' already exists."
    authorize_key
    exit 0
fi

echo "==> Creating self-signed code-signing certificate: $IDENTITY"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

KEY="$WORK/key.pem"
CRT="$WORK/cert.pem"
P12="$WORK/identity.p12"
P12_PASS="mterm"

cat > "$WORK/ext.cnf" <<EXT
[req]
distinguished_name = dn
x509_extensions    = v3
prompt             = no
[dn]
CN = $IDENTITY
[v3]
basicConstraints = critical,CA:true
keyUsage         = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EXT

"$OPENSSL" req -x509 -newkey rsa:2048 -nodes \
    -keyout "$KEY" -out "$CRT" -days 3650 \
    -config "$WORK/ext.cnf" >/dev/null 2>&1

"$OPENSSL" pkcs12 -export -inkey "$KEY" -in "$CRT" \
    -out "$P12" -name "$IDENTITY" -passout "pass:$P12_PASS" >/dev/null 2>&1

echo "==> Importing identity into the login keychain"
security import "$P12" -k "$KEYCHAIN" -P "$P12_PASS" \
    -T /usr/bin/codesign -T /usr/bin/security >/dev/null

authorize_key

echo
if security find-identity -p codesigning 2>/dev/null | grep -qF "$IDENTITY"; then
    echo "Done. '$IDENTITY' is a stable code-signing identity."
    echo "scripts/package.sh will use it automatically."
else
    echo "Error: '$IDENTITY' was imported but is not resolvable as a" >&2
    echo "codesigning identity. Check 'security find-identity -p codesigning'." >&2
    exit 1
fi
