#!/usr/bin/env bash
set -euo pipefail

if [ -z "${WEBHOOK:-}" ]; then
  echo "::error::webhook-url is empty. Set the Teams Workflows webhook URL (usually via a repo/org secret, e.g. secrets.TEAMS_WEBHOOK_URL). Note: secrets are not available to pull_request runs from forks."
  exit 1
fi
echo "::add-mask::$WEBHOOK"

API="${GITHUB_API_URL:-https://api.github.com}"
SERVER="${GITHUB_SERVER_URL:-https://github.com}"

gh_api() {
  curl -sS -H "Authorization: Bearer $GH_TOKEN" \
    -H "Accept: application/vnd.github+json" "$1"
}

if [ "$STATUS" = "success" ]; then
  COLOR="Good"; TITLE="✅ ${APP_NAME} build succeeded"
elif [ "$STATUS" = "cancelled" ]; then
  COLOR="Warning"; TITLE="⚠️ ${APP_NAME} build cancelled"
else
  COLOR="Attention"; TITLE="❌ ${APP_NAME} build ${STATUS}"
fi

COMMIT_MESSAGE=""
FILES_LIST=""
FILES_MORE=""
FILES_MORE_COUNT=0
if [ -n "$GH_TOKEN" ]; then
  COMMIT_JSON=$(gh_api "$API/repos/$REPO/commits/$SHA")
  COMMIT_MESSAGE=$(echo "$COMMIT_JSON" | jq -r '.commit.message // ""')
  FILE_COUNT=$(echo "$COMMIT_JSON" | jq -r '(.files // []) | length')
  # each filename links to its blob at this commit; path segments are
  # percent-encoded individually so '/' stays a separator, not %2F
  JQ_FILELINKS='def filelinks($base): map("• [" + . + "](" + $base + ((. / "/") | map(@uri) | join("/")) + ")") | join("\n");'
  FILES_LIST=$(echo "$COMMIT_JSON" | jq -r --arg base "$SERVER/$REPO/blob/$SHA/" --argjson max "$MAX_FILES" "
    $JQ_FILELINKS
    [(.files // [])[].filename][:\$max] | filelinks(\$base)
  ")
  if [ "$FILE_COUNT" -gt "$MAX_FILES" ]; then
    # the rest goes into a collapsed block the reader can expand in Teams
    FILES_MORE=$(echo "$COMMIT_JSON" | jq -r --arg base "$SERVER/$REPO/blob/$SHA/" --argjson max "$MAX_FILES" "
      $JQ_FILELINKS
      [(.files // [])[].filename][\$max:] | filelinks(\$base)
    ")
    FILES_MORE_COUNT=$((FILE_COUNT - MAX_FILES))
  fi
fi

# fmtdur turns seconds into "1h 2m 3s" (leading zero units dropped);
# $h/$m/$s below are jq variables, so no shell expansion is wanted here
# shellcheck disable=SC2016
JQ_FMTDUR='def fmtdur: floor
  | (. / 3600 | floor) as $h | (. % 3600 / 60 | floor) as $m | (. % 60) as $s
  | (if $h > 0 then "\($h)h " else "" end)
  + (if $h > 0 or $m > 0 then "\($m)m " else "" end)
  + "\($s)s";'

WORKFLOW_FACT=""
JOBS_LIST=""
JOBS_MORE=""
JOBS_MORE_COUNT=0
MAX_JOBS="${MAX_JOBS:-5}"
if [ -n "$GH_TOKEN" ] && [ -n "${RUN_ID:-}" ]; then
  RUN_JSON=$(gh_api "$API/repos/$REPO/actions/runs/$RUN_ID")

  # "[<workflow> #<run_number>](run url) — took 1m 30s" (duration = start → now)
  WORKFLOW_FACT=$(echo "$RUN_JSON" | jq -r --arg name "${WORKFLOW_NAME:-}" --arg url "$RUN_URL" "
    $JQ_FMTDUR
    if .run_number then
      \"[\(if \$name == \"\" then .name // \"workflow\" else \$name end) #\(.run_number)](\(\$url))\"
      + ((.run_started_at // .created_at) as \$t
         | if \$t then \" — took \(now - (\$t | fromdateiso8601) | fmtdur)\" else \"\" end)
    else \"\" end
  ")

  # auto-detect the PR when not passed explicitly
  if [ -z "${PR_NUMBER:-}" ]; then
    PR_NUMBER=$(echo "$RUN_JSON" | jq -r '(.pull_requests // [])[0].number // ""')
  fi

  # pull_request runs get a synthetic "N/merge" ref — show the real source branch instead
  case "$REF_NAME" in
    */merge)
      HEAD_REF=$(echo "$RUN_JSON" | jq -r '(.pull_requests // [])[0].head.ref // .head_branch // ""')
      if [ -n "$HEAD_REF" ]; then
        REF_NAME="$HEAD_REF"
        REF_URL="$SERVER/$REPO/tree/$HEAD_REF"
      fi
      ;;
  esac

  # per-job status + duration, e.g. "✓ [build](url) — 1m 12s"
  if [ "${INCLUDE_JOBS:-true}" = "true" ] || { [ "${INCLUDE_JOBS:-true}" = "on-failure" ] && [ "$STATUS" != "success" ]; }; then
    JOBS_JSON=$(gh_api "$API/repos/$REPO/actions/runs/$RUN_ID/jobs?per_page=100")
    JQ_JOBLINES="$JQ_FMTDUR
      def joblines: [(.jobs // [])[] | select(.status == \"completed\")
        | (if .conclusion == \"success\" then \"✓\"
           elif .conclusion == \"failure\" then \"✗\"
           else \"»\" end) as \$icon
        | \"\(\$icon) [\(.name)](\(.html_url))\"
          + (if .started_at and .completed_at then
               \" — \((.completed_at | fromdateiso8601) - (.started_at | fromdateiso8601) | fmtdur)\"
             else \"\" end)
      ];"
    JOBS_LIST=$(echo "$JOBS_JSON" | jq -r --argjson max "$MAX_JOBS" "
      $JQ_JOBLINES joblines[:\$max] | join(\"\n\")
    ")
    JOBS_TOTAL=$(echo "$JOBS_JSON" | jq -r '[(.jobs // [])[] | select(.status == "completed")] | length')
    if [ "$JOBS_TOTAL" -gt "$MAX_JOBS" ]; then
      # the rest goes into a collapsed block the reader can expand in Teams
      JOBS_MORE=$(echo "$JOBS_JSON" | jq -r --argjson max "$MAX_JOBS" "
        $JQ_JOBLINES joblines[\$max:] | join(\"\n\")
      ")
      JOBS_MORE_COUNT=$((JOBS_TOTAL - MAX_JOBS))
    fi
  fi
fi

PR_URL=""
if [ -n "${PR_NUMBER:-}" ]; then
  PR_URL="$SERVER/$REPO/pull/$PR_NUMBER"
fi

STATUS_UPPER=$(echo "$STATUS" | tr '[:lower:]' '[:upper:]')
SENT_AT=$(date -u +"%A, %d %B %Y, %H:%M UTC")

PAYLOAD_FILE="${RUNNER_TEMP:-/tmp}/teams-payload.json"

jq -n \
  --arg title "$TITLE" --arg color "$COLOR" \
  --arg ref "$REF_NAME" --arg event "$EVENT_NAME" --arg actor "$ACTOR" \
  --arg status "$STATUS_UPPER" --arg sentAt "$SENT_AT" \
  --arg refUrl "$REF_URL" \
  --arg repo "$REPO" --arg repoUrl "$SERVER/$REPO" \
  --arg message "$COMMIT_MESSAGE" --arg files "$FILES_LIST" \
  --arg runUrl "$RUN_URL" --arg commitUrl "$COMMIT_URL" \
  --arg prUrl "$PR_URL" \
  --arg workflow "$WORKFLOW_FACT" --arg jobs "$JOBS_LIST" \
  --arg filesMore "$FILES_MORE" --arg moreCount "$FILES_MORE_COUNT" \
  --arg jobsMore "$JOBS_MORE" --arg jobsMoreCount "$JOBS_MORE_COUNT" \
  '{
    type: "message",
    attachments: [{
      contentType: "application/vnd.microsoft.card.adaptive",
      content: {
        "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
        type: "AdaptiveCard",
        version: "1.4",
        body: (
          [
            { type: "TextBlock", size: "Medium", weight: "Bolder", color: $color, text: $title },
            { type: "FactSet", facts: (
              [
                { title: "Repository", value: "[\($repo)](\($repoUrl))" },
                { title: "Branch", value: "[\($ref)](\($refUrl))" }
              ]
              + (if $workflow == "" then [] else [{ title: "Workflow", value: $workflow }] end)
              + [
                { title: "Event",  value: $event },
                { title: "Status", value: $status },
                { title: "Actor",  value: $actor },
                { title: "Date",   value: $sentAt }
              ]
            )}
          ]
          + (if $jobs == "" then [] else [
              { type: "TextBlock", weight: "Bolder", text: "Jobs", spacing: "Medium" },
              { type: "TextBlock", text: $jobs, wrap: true, isSubtle: true }
            ] end)
          + (if $jobsMore == "" then [] else [
              { type: "TextBlock", id: "moreJobs", text: $jobsMore,
                wrap: true, isSubtle: true, isVisible: false, spacing: "None" },
              { type: "ColumnSet", id: "moreJobsToggle", spacing: "None",
                selectAction: { type: "Action.ToggleVisibility",
                                targetElements: ["moreJobs", "moreJobsToggle"] },
                columns: [
                  { type: "Column", width: "auto", items: [
                    { type: "TextBlock", text: "…and", isSubtle: true } ] },
                  { type: "Column", width: "stretch", spacing: "Small", items: [
                    { type: "TextBlock", text: "\($jobsMoreCount) more", color: "Accent" } ] }
                ] }
            ] end)
          + (if $message == "" then [] else [
              { type: "TextBlock", weight: "Bolder", text: "Commit message", spacing: "Medium" },
              { type: "TextBlock", text: $message, wrap: true, isSubtle: true }
            ] end)
          + (if $files == "" then [] else [
              { type: "TextBlock", weight: "Bolder", text: "Files changed", spacing: "Medium" },
              { type: "TextBlock", text: $files, wrap: true, isSubtle: true }
            ] end)
          + (if $filesMore == "" then [] else [
              { type: "TextBlock", id: "moreFiles", text: $filesMore,
                wrap: true, isSubtle: true, isVisible: false, spacing: "None" },
              { type: "ColumnSet", id: "moreFilesToggle", spacing: "None",
                selectAction: { type: "Action.ToggleVisibility",
                                targetElements: ["moreFiles", "moreFilesToggle"] },
                columns: [
                  { type: "Column", width: "auto", items: [
                    { type: "TextBlock", text: "• …and", isSubtle: true } ] },
                  { type: "Column", width: "stretch", spacing: "Small", items: [
                    { type: "TextBlock", text: "\($moreCount) more", color: "Accent" } ] }
                ] }
            ] end)
        ),
        actions: (
          [
            { type: "Action.OpenUrl", title: "View run",    url: $runUrl },
            { type: "Action.OpenUrl", title: "View commit", url: $commitUrl }
          ]
          + (if $prUrl == "" then [] else [{ type: "Action.OpenUrl", title: "View PR", url: $prUrl }] end)
        )
      }
    }]
  }' > "$PAYLOAD_FILE"

HTTP_CODE=$(curl -sS -o /dev/null -w "%{http_code}" -X POST -H "Content-Type: application/json" \
  -d @"$PAYLOAD_FILE" "$WEBHOOK")

echo "Teams webhook responded with HTTP $HTTP_CODE"
if [ "$HTTP_CODE" -ge 300 ]; then
  echo "::error::MS Teams webhook returned HTTP $HTTP_CODE"
  exit 1
fi
