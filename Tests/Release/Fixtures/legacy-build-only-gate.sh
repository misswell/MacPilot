#!/usr/bin/env bash
# Historical regression fixture adapted from release-common.yml at
# 67665f3b475c5e4e9c19417f1176d459f5897c81 with bounded immediate
# success/failure behavior. Keep this immutable in tests:
# origin/main moves after merge and must never become the source for old logic.
# This bounded mock preserves the old behavior: only build.yml is checked.
main_run="$(gh run list \
  --repo "$GITHUB_REPOSITORY" \
  --workflow build.yml \
  --commit "$GITHUB_SHA" \
  --json databaseId,headBranch,status,conclusion \
  --limit 20 \
  --jq '[.[] | select(.headBranch == "main")] | first')"
if [[ -z "$main_run" || "$main_run" == "null" ]]; then
  exit 1
fi
status="$(jq -r '.status' <<<"$main_run")"
conclusion="$(jq -r '.conclusion // empty' <<<"$main_run")"
[[ "$status" == completed && "$conclusion" == success ]]
