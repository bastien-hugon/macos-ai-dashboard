#!/bin/bash
# Incrémente la version (14 · REQ-LIC-46) : CFBundleShortVersionString = SemVer passé en
# argument, CFBundleVersion = compteur entier incrémenté. Usage : scripts/bump-version.sh 0.2.0
set -euo pipefail

VERSION="${1:?usage: bump-version.sh <x.y.z>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLIST="$ROOT/Apps/AgentDash/Resources/Info.plist"

CURRENT_BUILD="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST" 2>/dev/null || echo 0)"
NEXT_BUILD=$((CURRENT_BUILD + 1))

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEXT_BUILD" "$PLIST"

echo "✓ Version $VERSION (build $NEXT_BUILD)"
echo "  Pensez à ajouter une section '## $VERSION' dans CHANGELOG.md, puis :"
echo "  git commit -am 'release $VERSION' && git tag v$VERSION && git push --tags"
