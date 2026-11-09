# Sourced by make-signing-identity.sh and bundle.sh: where the local signing identity lives.
CORRAL_IDENTITY="${CORRAL_SIGN_IDENTITY:-Corral Local Signing}"
CORRAL_KEYCHAIN="$HOME/Library/Keychains/corral-signing.keychain-db"
CORRAL_KEYCHAIN_ACCOUNT=corral-signing
CORRAL_KEYCHAIN_SERVICE="Corral signing keychain"

# Unlocks the signing keychain; fails when the identity isn't there.
corral_unlock_signing() {
    [[ -f "$CORRAL_KEYCHAIN" ]] || return 1
    local pass
    pass=$(security find-generic-password -a "$CORRAL_KEYCHAIN_ACCOUNT" -s "$CORRAL_KEYCHAIN_SERVICE" -w 2>/dev/null) || return 1
    security unlock-keychain -p "$pass" "$CORRAL_KEYCHAIN" || return 1
    # A string match, not `| grep -q`: grep quitting early fails the pipe under pipefail.
    [[ "$(security find-identity -p codesigning "$CORRAL_KEYCHAIN")" == *"\"$CORRAL_IDENTITY\""* ]]
}
