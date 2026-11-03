#!/bin/bash
# Run before every push: all commits must be timemaster5, and no private data may be in the tree.
set -Eeuo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

want='timemaster5 <timemaster@trillinis.com>'
bad=0

while IFS='|' read -r author committer; do
	if [[ $author != "$want" || $committer != "$want" ]]; then
		echo "Wrong identity: author '$author', committer '$committer'" >&2
		bad=1
	fi
done < <(git log --format='%an <%ae>|%cn <%ce>')

if git log --format=%B | grep -qiE '^(co-authored-by|claude-session|signed-off-by):'; then
	echo 'Commit message trailer found' >&2
	bad=1
fi

# Private paths, addresses and tool mentions must not be published.
pattern='/Users/|/home/[a-z]|\b(10|192\.168|172\.(1[6-9]|2[0-9]|3[01]))\.[0-9]+\.[0-9]+(\.[0-9]+)?\b|codex|password *[:=]|BEGIN [A-Z ]*PRIVATE'
if git grep -nIiE "$pattern" -- . ':!tools/check-identity.sh'; then
	echo 'Private data found in the tree' >&2
	bad=1
fi

if (( bad )); then
	exit 1
fi
echo 'OK'
