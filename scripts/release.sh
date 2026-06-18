#!/bin/bash
set -e

# Default values (can be overridden by env or options)
PROJECT_DIR="${PROJECT_DIR:-.}"
RELEASE_DIR="${RELEASE_DIR:-./releases}"
RELEASE_REPO_URL="${RELEASE_REPO_URL:-}"

show_help() {
    cat <<EOF
Usage: $0 [OPTIONS]

Build and prepare a release of Modulash.

Options:
  --project-dir DIR   Path to the Modulash project (default: .)
  --release-dir DIR   Directory to store release files (default: ./releases)
  --release-repo URL  Git repository URL to push the release to (optional)
  --help              Show this help

Environment variables:
  PROJECT_DIR, RELEASE_DIR, RELEASE_REPO_URL can also be set.
EOF
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --project-dir)
            PROJECT_DIR="$2"
            shift 2
            ;;
        --release-dir)
            RELEASE_DIR="$2"
            shift 2
            ;;
        --release-repo)
            RELEASE_REPO_URL="$2"
            shift 2
            ;;
        --help)
            show_help
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# Resolve paths to absolute
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"
RELEASE_DIR="$(mkdir -p "$RELEASE_DIR" && cd "$RELEASE_DIR" && pwd)"

cd "$PROJECT_DIR"

if [[ ! -f "modulash.json" ]]; then
    echo "Error: modulash.json not found in $PROJECT_DIR"
    exit 1
fi

VERSION=$(jq -r '.version' modulash.json)
if [[ -z "$VERSION" || "$VERSION" == "null" ]]; then
    echo "Error: version not defined in modulash.json"
    exit 1
fi

echo "Building version $VERSION from $PROJECT_DIR..."
./bin/clish build --force --enable-debug

DIST_DIR="$PROJECT_DIR/dist"
BINARY_NAME="modulash-$VERSION"
cp "$DIST_DIR/modulash" "$RELEASE_DIR/$BINARY_NAME"
chmod +x "$RELEASE_DIR/$BINARY_NAME"

SHA256_FILE="$RELEASE_DIR/$BINARY_NAME.sha256"
sha256sum "$RELEASE_DIR/$BINARY_NAME" | awk '{print $1}' > "$SHA256_FILE"

# Update versions.json
VERSIONS_JSON="$RELEASE_DIR/versions.json"
# Use a base URL that can be overridden by environment
DOWNLOAD_URL_BASE="${DOWNLOAD_URL_BASE:-https://raw.githubusercontent.com/minidog888/modulash-releases/main}"
DOWNLOAD_URL="$DOWNLOAD_URL_BASE/$BINARY_NAME"
SHA256_VALUE=$(cat "$SHA256_FILE")

if [[ -f "$VERSIONS_JSON" ]]; then
    jq --arg v "$VERSION" --arg url "$DOWNLOAD_URL" --arg sha "$SHA256_VALUE" \
       '.stable.version=$v | .stable.download_url=$url | .stable.sha256=$sha' \
       "$VERSIONS_JSON" > "$VERSIONS_JSON.tmp"
    mv "$VERSIONS_JSON.tmp" "$VERSIONS_JSON"
else
    cat > "$VERSIONS_JSON" <<EOF
{
  "stable": {
    "version": "$VERSION",
    "download_url": "$DOWNLOAD_URL",
    "sha256": "$SHA256_VALUE"
  }
}
EOF
fi

echo "Release files prepared in $RELEASE_DIR:"
ls -lh "$RELEASE_DIR"

# Auto-push if RELEASE_REPO_URL is set
if [[ -n "$RELEASE_REPO_URL" ]]; then
    echo "Pushing to release repository: $RELEASE_REPO_URL"
    TMP_DIR="$(mktemp -d)"
    trap 'rm -rf "$TMP_DIR"' EXIT
    git clone "$RELEASE_REPO_URL" "$TMP_DIR"
    cp -r "$RELEASE_DIR"/* "$TMP_DIR/"
    cd "$TMP_DIR"
    git add .
    git commit -m "Release $VERSION" || echo "No changes to commit"
    git push origin HEAD:main
    echo "Push completed."
else
    echo ""
    echo "To push these files to a release repository, set RELEASE_REPO_URL or use --release-repo."
fi