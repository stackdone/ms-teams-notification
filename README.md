# MS Teams Notification (Adaptive Card)

[![CI](https://github.com/stackdone/ms-teams-notification/actions/workflows/ci.yml/badge.svg)](https://github.com/stackdone/ms-teams-notification/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Send a build/deploy notification to a Microsoft Teams channel as a proper
**Adaptive Card** — not the legacy MessageCard format that most existing
Teams actions still send.

## Why not the other Teams actions?

Microsoft retired the old Office 365 Connector "Incoming Webhook" in favor of
Teams **Workflows** (built on Power Automate). Workflows webhooks only accept
a payload of `{ "type": "message", "attachments": [{ "contentType":
"application/vnd.microsoft.card.adaptive", "content": {...} }] }`. Actions
built for the old connector send a `themeColor`/`sections` MessageCard, which
Workflows silently rejects (`Attachments is null` → `BadRequest`) — the
message never arrives and the job still reports success. This action posts
a native Adaptive Card, so it works with current Teams webhooks.

## What it sends

- Title with a ✅ / ⚠️ / ❌ status color
- Facts: repository, branch (the real source branch on PR runs, not `N/merge`),
  workflow (run number + total duration), event, status, actor, date
- Per-job breakdown: ✓/✗/» status, link and duration for every completed job
  (`include-jobs: on-failure` shows it only when something went wrong); long
  lists collapse behind a clickable "…and N more"
- The triggering commit's full message
- A clickable list of changed files (links to each file's blob at that commit);
  long lists collapse behind an expandable "Show N more files" button
- Buttons: **View run**, **View commit**, and **View PR** (added automatically
  when the run belongs to a pull request, or via `pr-number`)

The commit/files/jobs sections are optional — omit `github-token` to skip them
entirely (e.g. for notifications that aren't tied to a single commit). GitHub
Enterprise Server is supported out of the box via `GITHUB_API_URL` /
`GITHUB_SERVER_URL`.

## Usage

```yaml
jobs:
  build:
    # ... your build job ...

  notify:
    if: always()
    needs: [build]
    runs-on: ubuntu-latest
    permissions:
      contents: read   # commit message + changed files
      actions: read    # per-job statuses and durations
    steps:
      - name: Notify Teams
        uses: stackdone/ms-teams-notification@v1
        with:
          webhook-url: ${{ secrets.TEAMS_WEBHOOK_URL }}
          status: ${{ needs.build.result }}
          app-name: "my-app"
          github-token: ${{ secrets.GITHUB_TOKEN }}
```

Minimal — without `github-token` the commit/files/jobs sections are skipped,
only the status card with buttons is sent:

```yaml
- uses: stackdone/ms-teams-notification@v1
  with:
    webhook-url: ${{ secrets.TEAMS_WEBHOOK_URL }}
    status: ${{ needs.deploy.result }}
```

## Inputs

| Input          | Required | Default                                              | Description                                             |
|----------------|----------|-------------------------------------------------------|-----------------------------------------------------------|
| `webhook-url`  | yes      | —                                                     | Teams "Workflows" webhook URL                              |
| `status`       | yes      | —                                                     | `success` / `failure` / `cancelled` / any other string    |
| `app-name`     | no       | `github.repository`                                   | Name shown in the card title                               |
| `github-token` | no       | `""`                                                  | Enables commit message, changed-files and jobs lookup (needs `contents: read` + `actions: read`) |
| `include-jobs` | no       | `true`                                                | Per-job breakdown: `true` / `false` / `on-failure`            |
| `run-id`       | no       | `github.run_id`                                       | Run used for the workflow fact + jobs list                    |
| `workflow-name`| no       | `github.workflow`                                     | Workflow name shown in the card                               |
| `repo`         | no       | `github.repository`                                   | Used for API calls and link URLs                          |
| `sha`          | no       | `github.sha`                                          | Commit to look up and link to                              |
| `ref-name`     | no       | `github.ref_name`                                     | Branch/tag shown in the card                                |
| `event-name`   | no       | `github.event_name`                                   | Event shown in the card                                     |
| `actor`        | no       | `github.actor`                                        | Actor shown in the card                                     |
| `run-url`      | no       | link to the current run                              | "View run" button target                                    |
| `commit-url`   | no       | link to the commit                                   | "View commit" button target                                 |
| `ref-url`      | no       | link to the branch/tag tree                          | Branch/tag fact link target                                  |
| `pr-number`    | no       | auto-detected from the run                           | Overrides the PR used for the "View PR" button               |
| `max-files`    | no       | `5`                                                  | Changed files shown up front; the rest expand via a clickable "…and N more" |
| `max-jobs`     | no       | `5`                                                  | Jobs shown up front; the rest expand via a clickable "…and N more" |

## Setting up the webhook

In Teams: channel → **Workflows** → "Post to a channel when a webhook request
is received" → copy the generated URL into a repo secret (e.g.
`TEAMS_WEBHOOK_URL`). Do **not** use the deprecated "Incoming Webhook"
connector — it uses an incompatible payload format.
