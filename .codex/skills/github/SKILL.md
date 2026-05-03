---
name: github
description: |
  Drive GitHub issues, comments, labels, and PR linkage from inside a Symphony
  agent workspace using the `gh` CLI. Symphony does not inject a dynamic GitHub
  GraphQL tool; everything goes through `gh`.
---

# GitHub via `gh`

Symphony's GitHub backend assumes the `gh` CLI is installed and authenticated
in the agent workspace (`gh auth login` once per host). All issue and PR work
happens through `gh` commands; there is no `linear_graphql`-style dynamic tool.

## Primary tool

Use the `gh` CLI. It already carries the workspace's GitHub credentials.

For raw GraphQL when the high-level commands do not cover what you need:

```bash
gh api graphql -f query='<query>' -F variable=value
```

Send one operation per call. Treat a top-level `errors` array in the response
as a failed operation even if `gh` exited 0.

## Common workflows

### Read an issue

Use the issue number known to the agent (usually `{{ issue.identifier }}`,
which already starts with `#`):

```bash
gh issue view <number> --json id,number,title,body,state,labels,url,assignees,comments
```

### Search for issues

```bash
gh issue list \
  --state open \
  --label "status:in-progress" \
  --json number,title,url
```

For more advanced filters use `gh search issues` or `gh api graphql` with
`search(type: ISSUE, query: ...)`.

### Set status (mutually exclusive `status:*` labels)

State is encoded as one of `status:todo`, `status:in-progress`,
`status:human-review`, `status:merging`, `status:rework`, `status:done`. Apply
exactly one at a time by removing the previous one and adding the new one in a
single `gh issue edit` call:

```bash
gh issue edit <number> \
  --remove-label "status:in-progress" \
  --add-label "status:human-review"
```

If the destination label does not exist yet, Symphony's orchestrator
auto-creates it the first time it transitions an issue into that state. You can
also create it ahead of time:

```bash
gh label create "status:human-review" --color 5319e7 --description "Symphony status"
```

### Find or create the workpad comment

There is no comment-ID persistence layer. Workpads are identified solely by the
`## Codex Workpad` header at the top of the comment body.

Find the existing workpad:

```bash
gh issue view <number> --json comments \
  --jq '.comments[] | select(.body | startswith("## Codex Workpad"))'
```

If the result is empty, create one:

```bash
gh issue comment <number> --body-file - <<'EOF'
## Codex Workpad

```text
<hostname>:<abs-path>@<short-sha>
```

### Plan

- [ ] ...

### Acceptance Criteria

- [ ] ...

### Validation

- [ ] ...

### Notes

- ...
EOF
```

### Update the workpad comment

`gh issue comment` does not edit existing comments directly; use the GraphQL
API for in-place edits:

```bash
gh api graphql \
  -f query='mutation($id: ID!, $body: String!) { updateIssueComment(input: {id: $id, body: $body}) { issueComment { id } } }' \
  -F id="<comment-node-id>" \
  -F body="$(cat workpad.md)"
```

The comment node ID comes from the `gh issue view ... --json comments` lookup
above (each comment has an `id` field).

### Add an arbitrary comment

```bash
gh issue comment <number> --body-file - <<'EOF'
short note body here
EOF
```

### Open a PR linked to the issue

Include `Closes #<number>` in the PR body so GitHub auto-links and auto-closes
on merge. There is no separate `attachmentLinkGitHubPR`-style mutation needed.

```bash
gh pr create \
  --title "<title>" \
  --body "$(cat <<'EOF'
## Summary

- ...

## Test plan

- ...

Closes #<number>
EOF
)" \
  --label symphony
```

If the PR already exists, ensure the `symphony` label is present:

```bash
gh pr edit <pr-number> --add-label symphony
```

## Usage rules

- Use `gh` for issue reads, comment lifecycle, label changes, and PR creation.
- Use `gh api graphql` for things `gh` does not expose directly (in-place
  comment edits, advanced search filters, label CRUD).
- Status transitions are always remove-then-add of a `status:*` label so the
  issue ends up with exactly one status label.
- Workpad lookups always go through the `## Codex Workpad` header search.
- Link a PR to its issue with `Closes #<n>` in the PR body, not a custom
  attachment mutation.
- Do not write raw-token shell helpers; let `gh` carry session auth.
