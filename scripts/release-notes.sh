#!/bin/bash
# Prints the notes for one release: what changed (that version's section of CHANGELOG.md),
# then how to install.
#   scripts/release-notes.sh            notes for the version in apple/Resources/Info.plist
#   scripts/release-notes.sh 0.1.1      notes for that version
# Fails if CHANGELOG.md says nothing under "## <version>", so a release can't go out with
# notes that don't say what changed. The build runs this on every push and pull request.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/apple/Resources/Info.plist")}"

# The lines between "## <version>" and the next "## " heading, without leading blank lines.
CHANGES="$(awk -v v="$VERSION" '/^## / { on = ($2 == v); next } on { print }' "$ROOT/CHANGELOG.md" | sed '/./,$!d')"
if [ -z "$CHANGES" ]; then
  echo "CHANGELOG.md has nothing under \"## $VERSION\". Say what changed there before releasing." >&2
  exit 1
fi

printf '## What changed in %s\n\n%s\n\n' "$VERSION" "$CHANGES"
cat <<'EOF'
## Install

Universal app for Apple Silicon and Intel Macs, macOS 14 or later.

1. Download the zip, open it, and move Ledgerline to Applications.
2. The app is not notarized by Apple, so macOS blocks it the first time. Open it once, dismiss the warning, then go to System Settings > Privacy & Security and choose **Open Anyway**. You only need to do this once.

The `.sha256` file holds the checksum of the zip: `shasum -a 256 -c Ledgerline-*.zip.sha256`.
EOF
