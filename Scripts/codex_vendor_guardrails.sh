#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

ROOT="${REPOPROMPT_RELEASE_SOURCE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$ROOT"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

python3 Scripts/codex_runtime_artifact.py validate-manifest

for path in \
    ThirdPartyLicenses/codex/LICENSE \
    ThirdPartyLicenses/codex/NOTICE \
    ThirdPartyLicenses/codex/README.md \
    ThirdPartyLicenses/codex/ZSH-LICENCE \
    ThirdPartyLicenses/codex/SHA256SUMS; do
    [[ -f "$path" ]] || fail "Missing Codex legal inventory file: $path"
done

(
    cd ThirdPartyLicenses/codex
    unexpected_directory="$(find . -mindepth 1 -type d -print -quit)"
    [[ -z "$unexpected_directory" ]] ||
        fail "Codex legal inventory must remain flat; unexpected directory: $unexpected_directory"
    find . -maxdepth 1 -type f ! -name SHA256SUMS -print |
        sed 's#^./##' | sort > "$TMP_DIR/legal-files"
    awk '{ print $2 }' SHA256SUMS | sort > "$TMP_DIR/legal-sums"
    diff -u "$TMP_DIR/legal-files" "$TMP_DIR/legal-sums" ||
        fail "Codex legal checksum inventory is incomplete"
    shasum -a 256 -c SHA256SUMS
)

grep -F "## OpenAI Codex" THIRD_PARTY_NOTICES.md >/dev/null ||
    fail "THIRD_PARTY_NOTICES.md is missing the OpenAI Codex section"
grep -F "codex-resources/zsh/bin/zsh" THIRD_PARTY_NOTICES.md >/dev/null ||
    fail "THIRD_PARTY_NOTICES.md is missing the bundled Zsh notice"
grep -F "rust-v0.144.6" docs/releasing.md >/dev/null ||
    fail "docs/releasing.md is missing the pinned Codex release"

printf 'OK: pinned Codex artifact and legal inventory contracts are complete.\n'
