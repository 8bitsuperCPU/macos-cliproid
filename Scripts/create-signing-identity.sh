#!/usr/bin/env bash
#
# Creates a stable, self-signed code-signing identity for local builds.
#
# Why this exists: Scripts/bundle.sh otherwise signs ad-hoc (`--sign -`), which
# mints a brand-new code signature on every build. macOS keys both keychain
# access and TCC permissions (Accessibility, Screen Recording) to the signing
# identity, so every rebuild looks like a different application — which is why
# Nyx asks for those permissions again and again.
#
# A stable identity fixes all of it at once. The certificate lives in your login
# keychain, is trusted only by you, and signs nothing but local builds. It is
# not a Developer ID and cannot be used to distribute anything.
#
# For ClipRoid this is not a convenience, it is a prerequisite. The app needs
# Accessibility to deliver a synthetic Cmd+V and Screen Recording for the
# screenshot tool. Without a stable identity, every rebuild revokes both grants,
# and the resulting failures look exactly like code bugs — you spend an
# afternoon debugging a paste path that was never broken.
#
# Two things this cannot do for you, both of which also reset TCC grants:
#   - the bundle id must stay fixed (dev.philtronic.ClipRoid) from the start;
#   - TCC also keys on path, so build the bundle to a stable location.
#
# To deliberately re-test the first-run permission flow:
#   tccutil reset Accessibility dev.philtronic.ClipRoid
#
#   Scripts/create-signing-identity.sh          # create it
#   security delete-identity -c "ClipRoid Development"   # undo
#
set -euo pipefail

NAME="ClipRoid Development"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "$NAME"; then
    echo "\"$NAME\" already exists. Nothing to do."
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A run that imported the certificate and then failed before trusting it leaves
# one behind: an untrusted certificate is not an identity, so the check above
# cannot see it, and generating another would leave two of them in the keychain.
# Reuse what is there and carry on from where that run stopped.
if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "Found an untrusted \"$NAME\" from an earlier run. Reusing it."
    security find-certificate -c "$NAME" -p "$KEYCHAIN" > "$WORK/cert.pem"
else
    echo "Creating a self-signed code-signing certificate: $NAME"
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
        -subj "/CN=$NAME" \
        -addext "basicConstraints=critical,CA:false" \
        -addext "keyUsage=critical,digitalSignature" \
        -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

    # Two things here are not optional, and both fail as
    # "MAC verification failed during PKCS12 import (wrong password?)" — which is
    # neither about the MAC nor about a wrong password.
    #
    # The passphrase must be non-empty: Apple's importer and OpenSSL disagree about
    # how an empty one is encoded before the MAC is computed, so it never matches.
    # It is thrown away with $WORK on exit and never touches the keychain.
    #
    # The algorithms must be the legacy ones: OpenSSL 3 defaults to AES-256 with
    # PBKDF2 and a SHA-256 MAC, and Apple's importer reads none of that. Naming
    # them explicitly also works with the LibreSSL that ships as /usr/bin/openssl,
    # so this does not care which openssl is first on PATH.
    PASSPHRASE="$(openssl rand -hex 16)"
    openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
        -out "$WORK/identity.p12" -passout "pass:$PASSPHRASE" -name "$NAME" \
        -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1

    echo
    echo "Importing into your login keychain. macOS will ask for your password."
    security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASSPHRASE" \
        -T /usr/bin/codesign -T /usr/bin/security

fi

echo
echo "Marking it trusted for code signing. macOS will ask again."
# `trustRoot`, not `trustAsRoot`. The two are not interchangeable: trustAsRoot
# means "not a root, but treat it as one", and passing it for a self-signed
# certificate — which this is, subject and issuer both CN=ClipRoid Development — is
# rejected as "one or more parameters passed to a function were not valid".
security add-trusted-cert -d -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

# Without this, codesign raises a UI prompt for key access on every build.
#
# It has to be handed the login keychain password: unlike the two steps above,
# this one does not raise a dialog of its own, it just returns an error. The
# original empty `-k ""` therefore failed silently and left the prompts in
# place, which looked exactly like the script having worked.
echo
echo "Last step: letting codesign use the key without asking on every build."
echo "This needs your login keychain password — normally your account password."
printf "Password (or press return to skip): "
read -rs LOGIN_PASSWORD || true
echo

RETRY="security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k <password> \"$KEYCHAIN\""
if [[ -z "${LOGIN_PASSWORD:-}" ]]; then
    echo "  Skipped. Signing still works, but macOS will ask to use the key each build."
    echo "  To do it later:  $RETRY"
elif security set-key-partition-list -S apple-tool:,apple:,codesign: \
        -s -k "$LOGIN_PASSWORD" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "  Done."
else
    echo "  That was not accepted. Signing still works, but macOS will ask each build."
    echo "  To try again:  $RETRY"
fi
unset LOGIN_PASSWORD

echo
if security find-identity -v -p codesigning | grep -q "$NAME"; then
    echo "Done. Scripts/bundle.sh will use \"$NAME\" from now on."
    echo "Rebuild once, and the Accessibility and Screen Recording prompts should stop recurring."
else
    echo "The identity was not created. Builds will continue to sign ad-hoc."
    exit 1
fi
