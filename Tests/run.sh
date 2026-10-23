#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
CHECK_DIR=$(mktemp -d)
trap 'rm -rf "$CHECK_DIR"' EXIT
swiftc Folio/CloudSync.swift Folio/Library.swift Folio/DocumentIO.swift Folio/LibraryStore.swift Folio/Editor.swift Tests/SyncChecks.swift Tests/LibraryChecks.swift -o "$CHECK_DIR/library-checks"
"$CHECK_DIR/library-checks"
