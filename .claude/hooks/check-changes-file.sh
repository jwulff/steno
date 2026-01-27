#!/bin/bash
#
# Hook: check-changes-file.sh
# Checks if a PR has a corresponding changes file before merge
# Provides feedback to Claude suggesting one should be created if missing
#

set -e

# Read JSON input from stdin
input=$(cat)

# Extract the command being run
command=$(echo "$input" | jq -r '.tool_input.command // empty')

# Only check gh pr merge commands
if ! echo "$command" | grep -qE '^gh\s+pr\s+merge'; then
  exit 0
fi

# Extract PR number from command (handles: gh pr merge 123, gh pr merge, etc.)
pr_number=$(echo "$command" | grep -oE 'merge\s+[0-9]+' | grep -oE '[0-9]+' || true)

# If no PR number specified, gh uses current branch's PR
if [ -z "$pr_number" ]; then
  pr_number=$(gh pr view --json number -q '.number' 2>/dev/null || true)
fi

if [ -z "$pr_number" ]; then
  exit 0  # Can't determine PR, let it proceed
fi

# Get files changed in this PR
changed_files=$(gh pr view "$pr_number" --json files -q '.files[].path' 2>/dev/null || true)

# Check if any changes file was added/modified in this PR
if echo "$changed_files" | grep -qE '^changes/.*\.md$'; then
  exit 0  # Changes file exists, all good
fi

# Get PR title for context
pr_title=$(gh pr view "$pr_number" --json title -q '.title' 2>/dev/null || echo "Unknown")

# Check if this is a docs-only or trivial PR that might not need a changes file
if echo "$pr_title" | grep -qiE '^(docs:|chore:|ci:|test:|style:)'; then
  # Soft reminder for docs/chore PRs
  cat << EOF
<claude-hint>
PR #$pr_number "$pr_title" has no changes file.

This appears to be a docs/chore PR, so a changes file may not be required.
If this PR contains substantive changes, consider creating one before merging:
  changes/$(date +%Y-%m-%d-%H%M)-brief-description.md
</claude-hint>
EOF
  exit 0
fi

# For feature/fix PRs, strongly suggest a changes file
cat << EOF
<claude-hint priority="high">
PR #$pr_number "$pr_title" is missing a changes file.

Per project workflow, every PR should have a corresponding changes file documenting:
- Why the change was made
- How it was implemented
- Key design decisions
- What's next

Please create a changes file before merging:
1. Create: changes/$(date +%Y-%m-%d-%H%M)-brief-description.md
2. Use the template from changes/README.md
3. Commit and push to the PR branch
4. Then merge

You can proceed with the merge, but the changes file should really be added.
</claude-hint>
EOF

exit 0  # Don't block, just suggest
