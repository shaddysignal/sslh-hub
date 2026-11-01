#!/bin/sh
# Copy README.md to the Docker Hub repository overview.
#
# Environment:
#   DOCKERHUB_USERNAME    Docker Hub user with admin rights on the repository
#   DOCKERHUB_TOKEN       access token with read, write and delete scope
#   DOCKERHUB_REPOSITORY  namespace/name, for example shaddysignal/sslh-hub
#   SHORT_DESCRIPTION     optional one-liner shown in search results, 100 bytes max
#   README_FILE           defaults to README.md
#   LINK_BASE             optional, e.g. https://github.com/owner/repo/blob/master;
#                         relative links in the README are prefixed with it so
#                         they keep working on Docker Hub
#   DRY_RUN               set to 1 to show what would be sent without sending it
#
# Docker Hub allows 25000 bytes for the overview and 100 for the short
# description. The script fails instead of truncating, so nothing is lost
# silently.
set -eu

: "${DOCKERHUB_REPOSITORY:?set DOCKERHUB_REPOSITORY (namespace/name)}"
: "${README_FILE=README.md}"
: "${SHORT_DESCRIPTION=}"
: "${LINK_BASE=}"
: "${DRY_RUN=0}"
API=https://hub.docker.com/v2

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM

# Make relative links absolute: "](path)" becomes "](LINK_BASE/path)". Links
# with a scheme (they contain ':') and anchors (they start with '#') are left
# alone.
if [ -n "$LINK_BASE" ]; then
    sed -E "s#\]\(([A-Za-z0-9_./-]+)\)#](${LINK_BASE%/}/\1)#g" "$README_FILE" > "$work/full.md"
else
    cp "$README_FILE" "$work/full.md"
fi

full_bytes=$(wc -c < "$work/full.md")
short_bytes=$(printf '%s' "$SHORT_DESCRIPTION" | wc -c)
if [ "$full_bytes" -gt 25000 ]; then
    echo "README is $full_bytes bytes; Docker Hub allows 25000" >&2
    exit 1
fi
if [ "$short_bytes" -gt 100 ]; then
    echo "short description is $short_bytes bytes; Docker Hub allows 100" >&2
    exit 1
fi

jq -n --rawfile full "$work/full.md" --arg short "$SHORT_DESCRIPTION" \
    '{full_description: $full} + (if $short != "" then {description: $short} else {} end)' \
    > "$work/payload.json"

echo "repository:        $DOCKERHUB_REPOSITORY"
echo "overview:          $full_bytes bytes from $README_FILE"
if [ -n "$SHORT_DESCRIPTION" ]; then
    echo "short description: $SHORT_DESCRIPTION ($short_bytes bytes)"
fi
if [ -n "$LINK_BASE" ]; then
    echo "rewritten links:"
    grep -oE "\]\(${LINK_BASE%/}/[^)]+\)" "$work/full.md" | sed 's/^/  /' || true
fi

if [ "$DRY_RUN" = 1 ]; then
    echo "dry run: nothing sent"
    exit 0
fi

: "${DOCKERHUB_USERNAME:?set DOCKERHUB_USERNAME}"
: "${DOCKERHUB_TOKEN:?set DOCKERHUB_TOKEN}"

# Exchange the access token for a short-lived API token.
jq -n --arg u "$DOCKERHUB_USERNAME" --arg s "$DOCKERHUB_TOKEN" \
    '{identifier: $u, secret: $s}' > "$work/login.json"
jwt=$(curl -fsS --max-time 30 --retry 3 -X POST -H 'Content-Type: application/json' \
        --data @"$work/login.json" "$API/auth/token" | jq -r '.access_token // empty')
if [ -z "$jwt" ]; then
    echo "Docker Hub login failed for $DOCKERHUB_USERNAME" >&2
    exit 1
fi
if [ -n "${GITHUB_ACTIONS-}" ]; then
    echo "::add-mask::$jwt"
fi

curl -fsS --max-time 60 --retry 3 -X PATCH \
    -H "Authorization: Bearer $jwt" -H 'Content-Type: application/json' \
    --data @"$work/payload.json" "$API/repositories/$DOCKERHUB_REPOSITORY" \
    | jq -r '"updated \(.namespace)/\(.name): short description \"\(.description)\", overview \(.full_description | length) characters"'
