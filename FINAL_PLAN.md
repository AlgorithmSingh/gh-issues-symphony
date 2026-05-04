# Symphony → GitHub Issues port: final plan (working version)

This is the trimmed, ship-it version of the port. Targets a working GitHub-backed
Symphony in ~2 days, not a polished 5-day rollout. Cuts: no mix seed task, no
live e2e suite, no migration doc, no rate-limit warning logger, no three-PR
phased rollout. Linear is removed in the same change as GitHub being added.

## Design decisions (locked)

- **`issue.id`** = GitHub Issue **node ID** (`I_kwDO…`), not the number. Stable,
  repo-namespaced, works directly with `nodes(ids:)`.
- **`issue.identifier`** = `"#142"` (human-readable).
- **State storage** = labels with prefix `status:` (`status:todo`,
  `status:in-progress`, …). Mutual exclusion enforced on write
  (remove-then-add); read-side picks first match and logs a warning if >1.
- **State→label query** = GitHub GraphQL `search(type: ISSUE, query: ...)` with
  comma-separated `label:` for OR semantics. **Verify this in a 30-minute spike
  before writing the adapter.** If `label:"status:todo","status:in-progress"`
  doesn't OR the way we expect, fall back to one query per state.
- **Blockers** = `blocked_by: []` in v1. Document the `blocked-by:#42` label
  convention as a manual escape hatch. Skip `trackedInIssues` (depends on
  sub-issues feature, not universally available).
- **Branch name** = synthesized — `"symphony/issue-#{number}-#{slug(title)}"`,
  truncated. The agent prompt template currently uses `issue.branch_name`;
  don't break it by leaving the field nil.
- **Auth** = three fallbacks in order: `tracker.api_key` → `GH_TOKEN` /
  `GITHUB_TOKEN` env → `gh auth token` shellout. Memoize the resolved token.
- **Agent-side writes** = no dynamic tool. Agent uses `gh` CLI directly. The
  Linear-era `linear_graphql` dynamic tool exists only because Linear has no
  CLI; GitHub does, so delete the tool.
- **Polling cadence** = 30s default (was 5s for Linear). GitHub's secondary
  rate limits will not tolerate 5s.

## Open question to resolve before coding

Does it make sense to shell out to `gh api graphql` from the **orchestrator**
too, instead of writing an Elixir HTTP client? Tradeoff: ~50ms subprocess
overhead per poll vs. ~300 lines of Req-based client code, token resolution,
and error mapping. Default answer: **keep the Req-based client** for
performance and to avoid a hard `gh` dependency on the orchestrator host
(only the agent workspace needs `gh`). But write this decision down so it's
not silently re-litigated later.

---

## File changes

### New
```
elixir/lib/symphony_elixir/issue.ex                  # generic, moved from linear/
elixir/lib/symphony_elixir/github/client.ex          # Req-based GraphQL client
elixir/lib/symphony_elixir/github/adapter.ex         # implements Tracker behaviour
elixir/test/symphony_elixir/github/adapter_test.exs
elixir/test/symphony_elixir/github/client_test.exs
elixir/test/fixtures/github/search_issues_response.json
elixir/test/fixtures/github/issues_by_id_response.json
.codex/skills/github/SKILL.md                        # replaces linear/SKILL.md
```

### Modified
| File | Change |
|------|--------|
| `lib/symphony_elixir/tracker.ex` | Replace catch-all with explicit `"github"` / `"linear"` (raise on unknown) |
| `lib/symphony_elixir/config/schema.ex` | Add `repo`, `state_label_prefix`. Kind-aware required-field validation. Kind-aware env fallback (`GH_TOKEN`/`GITHUB_TOKEN`). Reject `project_slug` when `kind: github` and vice versa. |
| `lib/symphony_elixir/codex/dynamic_tool.ex` | `tool_specs/0` returns `[]` for `kind: github`. Strip Linear branch when Linear is deleted. |
| `lib/symphony_elixir/prompt_builder.ex` + every `alias` site | `Linear.Issue` → `SymphonyElixir.Issue` |
| `lib/symphony_elixir/tracker/memory.ex` | Update alias |
| `WORKFLOW.md` | Rewrite for `kind: github`, polling 30s, drop Linear MCP prereq |
| `elixir/README.md` | Replace Linear setup section with `gh auth login` flow |

### Deleted (same PR as adding GitHub)
```
elixir/lib/symphony_elixir/linear/
.codex/skills/linear/
elixir/test/symphony_elixir/linear*
```

---

## `Issue` struct (unchanged shape, new namespace)

```elixir
defmodule SymphonyElixir.Issue do
  defstruct [
    :id,            # opaque tracker key (GitHub node ID)
    :identifier,    # human-readable ("#142")
    :title,
    :description,
    :priority,      # nil for GitHub
    :state,         # derived from status:* label
    :branch_name,   # synthesized for GitHub
    :url,
    :assignee_id,   # GitHub login string
    blocked_by: [],
    labels: [],
    assigned_to_worker: true,
    created_at: nil,
    updated_at: nil
  ]
end
```

Field shape matches the existing `Linear.Issue` exactly so every `%Issue{}`
pattern match in `orchestrator.ex` and `agent_runner.ex` keeps working.

---

## `GitHub.Client`

### Queries

**Candidate poll (single query, OR over status labels):**
```graphql
query SymphonyGitHubPoll($q: String!, $first: Int!, $after: String) {
  search(query: $q, type: ISSUE, first: $first, after: $after) {
    nodes {
      ... on Issue {
        id number title body url state createdAt updatedAt
        repository { nameWithOwner }
        assignees(first: 5) { nodes { login } }
        labels(first: 50) { nodes { name } }
      }
    }
    pageInfo { hasNextPage endCursor }
  }
}
```

`$q` is built as
`repo:owner/name is:issue is:open label:"status:todo","status:in-progress",...`.

**Lookup by IDs:**
```graphql
query SymphonyGitHubIssuesById($ids: [ID!]!) {
  nodes(ids: $ids) {
    ... on Issue { id number title body url state createdAt updatedAt
      repository { nameWithOwner }
      assignees(first: 5) { nodes { login } }
      labels(first: 50) { nodes { name } } }
  }
}
```

**Viewer (for `assignee: "me"`):** `query { viewer { login } }`.

### Headers
```
Authorization: bearer <token>
Content-Type: application/json
User-Agent: symphony-elixir
X-Github-Next-Global-ID: 1
```

### `normalize_issue/2`
- `id` ← node id
- `identifier` ← `"#" <> Integer.to_string(number)`
- `state` ← first label starting with `status:`, prefix stripped, **kept
  lowercased** (don't humanize — `Config.Schema.normalize_issue_state/1`
  lowercases both sides for comparison anyway). **Override:** if GitHub's
  native `state == CLOSED` and the derived label-state is in
  `active_states`, treat the issue as terminal (set state to `nil` so the
  reconciler stops the worker). Defends against label drift from a manual UI
  close on an `status:in-progress` issue, which would otherwise leave the
  worker spinning on a closed ticket.
- `branch_name` ← `"symphony/issue-#{number}-#{slug(title)}"` truncated to 64
  chars
- `priority` ← `nil`
- `assignee_id` ← first assignee's `login`, or the one matching configured
  `tracker.assignee` if set
- `assigned_to_worker?` ← match against `assignees[].login`. For
  `tracker.assignee == "me"`, resolve via `viewer { login }` once and cache.
- `blocked_by` ← `[]` (v1)
- `labels` ← all label names, lowercased (matches existing Linear behavior)

### Auth resolution
```elixir
defp resolve_token do
  with nil <- Config.settings!().tracker.api_key,
       nil <- System.get_env("GH_TOKEN"),
       nil <- System.get_env("GITHUB_TOKEN") do
    case System.cmd("gh", ["auth", "token"], stderr_to_stdout: true) do
      {token, 0} -> {:ok, String.trim(token)}
      _ -> {:error, :missing_github_auth}
    end
  else
    token -> {:ok, token}
  end
end
```
Memoize after first resolve.

---

## `GitHub.Adapter`

Mirrors `Linear.Adapter` callback set. Two writes only.

### `create_comment/2`
```graphql
mutation($subjectId: ID!, $body: String!) {
  addComment(input: {subjectId: $subjectId, body: $body}) {
    clientMutationId
  }
}
```
Returns `:ok | {:error, _}`. **Don't try to extract a comment ID** — the
existing `Tracker.create_comment` contract is `:ok | {:error, _}` and the
workpad protocol finds comments by header text, not by stored ID.

### `update_issue_state/2`
Three-step transaction:
1. Read current labels for the issue (`node(id: $id) { labels(first:50) { nodes { id name } } }`).
2. Find every label starting with `status:` and call
   `removeLabelsFromLabelable` with their IDs. (Defensive: there should be 0
   or 1, but handle >1 by removing all and logging a warning.)
3. Compute target label name = `"status:" <> slug(state_name)`. Resolve its
   ID; if it doesn't exist, `createLabel` with a default color, then
   `addLabelsToLabelable`.

Auto-creating labels on demand replaces the rejected `mix github.seed_labels`
task. Default colors keyed off state name (todo→grey, in-progress→blue,
human-review→purple, merging→yellow, rework→orange, done→green,
cancelled→red); fall through to `cccccc`.

Race risk: if two transitions race, the issue could end up with two
`status:*` labels. The orchestrator never calls `update_issue_state` itself
(only the agent does), and per-issue work is single-agent, so this is
acceptable for v1. Read-side defense logs the anomaly.

---

## Config schema additions

```elixir
embedded_schema do
  field :kind, :string                              # linear | github | memory
  field :endpoint, :string
  field :api_key, :string
  field :project_slug, :string                      # linear only
  field :repo, :string                              # github only
  field :assignee, :string
  field :active_states, {:array, :string}, default: ["Todo", "In Progress"]
  field :terminal_states, {:array, :string}, default: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]
  field :state_label_prefix, :string, default: "status:"   # github only
end
```

Validation:
- `kind: "github"` → require `repo` matching `~r/^[\w.-]+\/[\w.-]+$/`,
  forbid `project_slug`, default `endpoint` to `https://api.github.com/graphql`.
- `kind: "linear"` → require `project_slug`, forbid `repo`, default endpoint.
- `kind: "memory"` → no extra requirements.

`finalize_settings/1` env fallback becomes kind-aware:
```elixir
api_key_env =
  case settings.tracker.kind do
    "github" -> System.get_env("GH_TOKEN") || System.get_env("GITHUB_TOKEN")
    "linear" -> System.get_env("LINEAR_API_KEY")
    _ -> nil
  end
```

---

## Tracker dispatch

```elixir
def adapter do
  case Config.settings!().tracker.kind do
    "memory" -> SymphonyElixir.Tracker.Memory
    "github" -> SymphonyElixir.GitHub.Adapter
    "linear" -> SymphonyElixir.Linear.Adapter   # removed when Linear deleted
    other    -> raise "unsupported tracker.kind: #{inspect(other)}"
  end
end
```

The previous catch-all silently routed unknowns to Linear — that's a footgun
for typos in `WORKFLOW.md`. Replace with explicit raise.

---

## WORKFLOW.md rewrite

Frontmatter:
```yaml
tracker:
  kind: github
  repo: "owner/name"
  state_label_prefix: "status:"
  active_states: [Todo, "In Progress", Merging, Rework]
  terminal_states: [Done, Closed, Cancelled]
polling:
  interval_ms: 30000
agent:
  max_concurrent_agents: 5
codex:
  command: codex --config 'model="gpt-5.5"' app-server
  approval_policy: never
  thread_sandbox: workspace-write
```

Body: same structure as the current Linear WORKFLOW.md but with these swaps:

| Old | New |
|---|---|
| "Linear ticket" | "GitHub issue" |
| `linear_graphql` tool reference | `gh` CLI |
| `commentCreate` mutation | `gh issue comment <number> --body-file -` |
| `issueUpdate { stateId }` | `gh issue edit <number> --remove-label "status:in-progress" --add-label "status:human-review"` |
| `attachmentLinkGitHubPR` | (delete — `Closes #N` in PR body auto-links) |
| Workpad-by-comment-ID | Workpad-by-header-search (`gh issue view <n> --json comments --jq '.comments[] \| select(.body \| startswith("## Codex Workpad"))'`) |

Sandbox note: confirm `gh` works under `thread_sandbox: workspace-write`
(needs network egress). Document the policy if not.

Trust posture note: the agent invokes `gh` with the workspace's ambient
token, which has whatever scope the operator granted it. Unlike the
Linear-era `linear_graphql` tool, there is no orchestrator-side chokepoint
narrowing what the agent can do — the token can in principle write to any
repo, branch, or issue it has access to. WORKFLOW.md MUST state the
expected token scope (recommended: a fine-grained PAT limited to the
single `repo` configured in the tracker block, with Issues + Pull Requests
write only). A scoped wrapper around `gh` is a v2 conversation.

---

## Skill rewrite (`.codex/skills/github/SKILL.md`)

One-to-one mapping table, mirroring the Linear skill structure. Key flows:

- **Set status**: `gh issue edit <n> --remove-label "status:<old>" --add-label "status:<new>"`
- **Comment**: `gh issue comment <n> --body-file -` (heredoc body)
- **Find/upsert workpad**: search comments for `## Codex Workpad` header;
  reuse if found, else create
- **Link PR**: include `Closes #<n>` in PR body — GitHub handles linkage

Emphasize the workpad header convention since there's no comment-ID
persistence layer.

---

## Tests (v1 scope)

- `client_test.exs`
  - Auth resolution priority (config > env > shellout, mocked)
  - Search query string is built correctly from `active_states`
  - Pagination merges pages in stable order
  - `normalize_issue/2`: derives state from `status:*` label, lowercased;
    leaves it nil when no status label present
  - Synthesized `branch_name` shape and length cap
  - `assignee: "me"` resolves to `viewer.login`
- `adapter_test.exs`
  - `create_comment` returns `:ok` on success, `{:error, _}` on GraphQL errors
  - `update_issue_state` issues remove-then-add in order
  - `update_issue_state` creates the label on 422, then retries the add
  - Multiple existing `status:*` labels → all removed, warning logged

Skip: live e2e against a real repo. Add later if regressions warrant.

---

## Things explicitly NOT in v1

- Mix task to seed labels (auto-create on demand instead)
- Live e2e test (`make e2e-github`)
- Migration guide / Linear→GitHub porting script
- Rate-limit warning logger (Req absorbs transient 502s)
- `trackedInIssues`-based blocker extraction
- Projects v2 status-field adapter
- Backwards-compat shim keeping the Linear path alive after this PR
- Three-PR rollout with bake-in period

Add any of these only when there's evidence someone needs them.

---

## Risks worth naming

1. **Search API OR-over-labels semantics**. The whole single-query design
   depends on `label:"a","b"` meaning OR. Verify in the 30-minute spike
   before writing the client. If wrong, fall back to one query per state and
   merge with `Task.async_stream`.
2. **Labels don't enforce mutual exclusion**. A manual edit in the GitHub UI
   can leave an issue with two `status:*` labels. Read-side picks the first;
   single-agent-per-issue means write-side races are rare. Acceptable.
3. **GitHub has no priority field**. Orchestrator dispatch falls back to
   `created_at` ordering. Teams that need priority can use `priority:p0`-style
   labels and add a parser later.
4. **`gh` is required on agent hosts**. Already true today via the commit/push
   skills, but the README needs to call it out as a hard prerequisite.
5. **Sub-issue blockers absent in v1**. Teams relying on Linear's typed
   `blocks` relation lose ordering signal. Document the `blocked-by:#42`
   label convention as a workaround.

---

## Effort

| Step | Effort |
|---|---|
| Search-API spike | 30 min |
| Rename `Issue` + alias sweep | 30 min |
| Schema changes + tests | 1.5 hr |
| `GitHub.Client` (search + auth + normalize) | 4 hr |
| `GitHub.Adapter` (comment + label-swap with auto-create) | 2 hr |
| Tracker dispatch + dynamic_tool prune + delete Linear | 1 hr |
| WORKFLOW.md rewrite | 1 hr |
| Skill rewrite | 2 hr |
| Unit tests (fixtures + adapter + client) | 3 hr |
| README update | 30 min |
| **Total** | **~16 hours / 2 working days** |

---

## First action

30-minute spike: from a shell with `gh auth login` already done and a test
repo with `status:todo` + `status:in-progress` labels seeded on a couple of
issues, run:

```bash
gh api graphql -f query='
  query($q: String!) {
    search(query: $q, type: ISSUE, first: 10) {
      nodes { ... on Issue { number title labels(first:5){nodes{name}} } }
    }
  }' -f q='repo:OWNER/REPO is:issue is:open label:"status:todo","status:in-progress"'
```

Confirm both issues come back. If they do, proceed to Phase 1 (rename
`Issue`). If only AND-matched issues come back, swap the design to per-state
parallel queries before writing `GitHub.Client`.
