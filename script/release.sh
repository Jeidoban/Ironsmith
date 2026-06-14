#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

cd "$REPO_ROOT"

usage() {
    echo "Usage: $0 [major|minor|patch]" >&2
}

release_type="${1:-}"

if [[ -n "$release_type" && $# -ne 1 ]]; then
    usage
    exit 1
fi

if [[ -z "$release_type" ]]; then
    echo "Select release type:"
    select selected_release_type in patch minor major; do
        case "$selected_release_type" in
            major | minor | patch)
                release_type="$selected_release_type"
                break
                ;;
            *)
                echo "Please choose 1, 2, or 3."
                ;;
        esac
    done
fi

case "$release_type" in
    major | minor | patch)
        ;;
    *)
        usage
        exit 1
        ;;
esac

if [[ -n "$(git status --porcelain)" ]]; then
    echo "Working tree must be clean before creating a release tag." >&2
    git status --short
    exit 1
fi

git fetch --tags --prune-tags origin

latest_tag="$(
    git tag --list "v*" --sort=-v:refname |
        awk '$0 ~ /^v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*$/ { print; exit }'
)"

if [[ -z "$latest_tag" ]]; then
    major=0
    minor=0
    patch=0
else
    version="${latest_tag#v}"
    IFS="." read -r major minor patch <<< "$version"
fi

case "$release_type" in
    major)
        ((major += 1))
        minor=0
        patch=0
        ;;
    minor)
        ((minor += 1))
        patch=0
        ;;
    patch)
        ((patch += 1))
        ;;
esac

next_tag="v${major}.${minor}.${patch}"

if git rev-parse --quiet --verify "refs/tags/$next_tag" >/dev/null; then
    echo "Tag $next_tag already exists." >&2
    exit 1
fi

short_sha="$(git rev-parse --short HEAD)"
branch_name="$(git branch --show-current)"

echo "Latest stable tag: ${latest_tag:-none}"
echo "Next tag: $next_tag"
echo "Commit: $short_sha${branch_name:+ on $branch_name}"
read -r -p "Create and push $next_tag to origin? [y/N] " confirmation

case "$confirmation" in
    y | Y | yes | YES | Yes)
        ;;
    *)
        echo "Canceled."
        exit 0
        ;;
esac

git tag -a "$next_tag" -m "Release $next_tag"
git push origin "$next_tag"
