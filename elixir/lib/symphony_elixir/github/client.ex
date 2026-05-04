defmodule SymphonyElixir.GitHub.Client do
  @moduledoc """
  Thin GitHub GraphQL client for polling candidate issues and resolving label IDs.
  """

  require Logger
  alias SymphonyElixir.{Config, Issue}

  @issue_page_size 50
  @max_error_body_log_bytes 1_000

  @search_query """
  query SymphonyGitHubPoll($q: String!, $first: Int!, $after: String) {
    search(query: $q, type: ISSUE, first: $first, after: $after) {
      nodes {
        ... on Issue {
          id
          number
          title
          body
          url
          state
          createdAt
          updatedAt
          repository { nameWithOwner }
          assignees(first: 5) { nodes { login } }
          labels(first: 50) { nodes { name } }
        }
      }
      pageInfo { hasNextPage endCursor }
    }
  }
  """

  @issues_by_id_query """
  query SymphonyGitHubIssuesById($ids: [ID!]!) {
    nodes(ids: $ids) {
      ... on Issue {
        id
        number
        title
        body
        url
        state
        createdAt
        updatedAt
        repository { nameWithOwner }
        assignees(first: 5) { nodes { login } }
        labels(first: 50) { nodes { name } }
      }
    }
  }
  """

  @viewer_query """
  query SymphonyGitHubViewer { viewer { login } }
  """

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    tracker = Config.settings!().tracker

    cond do
      not is_binary(tracker.repo) or tracker.repo == "" ->
        {:error, :missing_github_repo}

      true ->
        with {:ok, viewer_login} <- maybe_resolve_viewer_login(tracker.assignee) do
          do_fetch_by_states(tracker.repo, tracker.active_states, tracker.state_label_prefix, tracker.assignee, viewer_login)
        end
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    normalized_states = state_names |> Enum.map(&to_string/1) |> Enum.uniq()

    if normalized_states == [] do
      {:ok, []}
    else
      tracker = Config.settings!().tracker

      cond do
        not is_binary(tracker.repo) or tracker.repo == "" ->
          {:error, :missing_github_repo}

        true ->
          do_fetch_by_states(tracker.repo, normalized_states, tracker.state_label_prefix, nil, nil)
      end
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    ids = Enum.uniq(issue_ids)

    case ids do
      [] ->
        {:ok, []}

      ids ->
        tracker = Config.settings!().tracker

        with {:ok, viewer_login} <- maybe_resolve_viewer_login(tracker.assignee) do
          do_fetch_issue_states(ids, tracker.assignee, viewer_login)
        end
    end
  end

  @spec graphql(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def graphql(query, variables \\ %{}, opts \\ [])
      when is_binary(query) and is_map(variables) and is_list(opts) do
    payload = build_graphql_payload(query, variables, Keyword.get(opts, :operation_name))
    request_fun = Keyword.get(opts, :request_fun, &post_graphql_request/2)

    with {:ok, headers} <- graphql_headers(),
         {:ok, %{status: 200, body: body}} <- request_fun.(payload, headers) do
      {:ok, body}
    else
      {:ok, response} ->
        Logger.error(
          "GitHub GraphQL request failed status=#{response.status}" <>
            github_error_context(payload, response)
        )

        {:error, {:github_api_status, response.status}}

      {:error, reason} ->
        Logger.error("GitHub GraphQL request failed: #{inspect(reason)}")
        {:error, {:github_api_request, reason}}
    end
  end

  @doc false
  @spec normalize_issue_for_test(map()) :: Issue.t() | nil
  def normalize_issue_for_test(issue) when is_map(issue) do
    normalize_issue(issue, nil, nil)
  end

  @doc false
  @spec normalize_issue_for_test(map(), String.t() | nil, String.t() | nil) :: Issue.t() | nil
  def normalize_issue_for_test(issue, configured_assignee, viewer_login)
      when is_map(issue) do
    normalize_issue(issue, configured_assignee, viewer_login)
  end

  @doc false
  @spec build_search_query_for_test(String.t(), [String.t()], String.t(), String.t() | nil, String.t() | nil) :: String.t()
  def build_search_query_for_test(repo, states, prefix, configured_assignee, viewer_login) do
    build_search_query(repo, states, prefix, configured_assignee, viewer_login)
  end

  @doc false
  @spec slug_for_test(String.t()) :: String.t()
  def slug_for_test(value), do: slug(value)

  @doc false
  @spec branch_name_for_test(integer(), String.t()) :: String.t()
  def branch_name_for_test(number, title), do: synthesize_branch_name(number, title)

  @doc false
  @spec resolve_token_for_test() :: {:ok, String.t()} | {:error, term()}
  def resolve_token_for_test, do: resolve_token()

  @doc false
  @spec reset_memoized_token_for_test() :: :ok
  def reset_memoized_token_for_test do
    Application.delete_env(:symphony_elixir, :github_resolved_token)
    Application.delete_env(:symphony_elixir, :github_viewer_login)
    :ok
  end

  defp do_fetch_by_states(repo, state_names, prefix, configured_assignee, viewer_login) do
    query = build_search_query(repo, state_names, prefix, configured_assignee, viewer_login)
    do_fetch_by_states_page(query, configured_assignee, viewer_login, nil, [])
  end

  defp do_fetch_by_states_page(query, configured_assignee, viewer_login, after_cursor, acc_issues) do
    with {:ok, body} <-
           graphql(@search_query, %{
             q: query,
             first: @issue_page_size,
             after: after_cursor
           }),
         {:ok, issues, page_info} <- decode_search_page_response(body, configured_assignee, viewer_login) do
      updated_acc = prepend_page_issues(issues, acc_issues)

      case next_page_cursor(page_info) do
        {:ok, next_cursor} ->
          do_fetch_by_states_page(query, configured_assignee, viewer_login, next_cursor, updated_acc)

        :done ->
          {:ok, finalize_paginated_issues(updated_acc)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp prepend_page_issues(issues, acc_issues) when is_list(issues) and is_list(acc_issues) do
    Enum.reverse(issues, acc_issues)
  end

  defp finalize_paginated_issues(acc_issues) when is_list(acc_issues), do: Enum.reverse(acc_issues)

  defp do_fetch_issue_states(ids, configured_assignee, viewer_login) do
    do_fetch_issue_states_page(ids, configured_assignee, viewer_login, [], issue_order_index(ids))
  end

  defp do_fetch_issue_states_page([], _configured_assignee, _viewer_login, acc_issues, issue_order_index) do
    acc_issues
    |> finalize_paginated_issues()
    |> sort_issues_by_requested_ids(issue_order_index)
    |> then(&{:ok, &1})
  end

  defp do_fetch_issue_states_page(ids, configured_assignee, viewer_login, acc_issues, issue_order_index) do
    {batch_ids, rest_ids} = Enum.split(ids, @issue_page_size)

    case graphql(@issues_by_id_query, %{ids: batch_ids}) do
      {:ok, body} ->
        with {:ok, issues} <- decode_nodes_response(body, configured_assignee, viewer_login) do
          updated_acc = prepend_page_issues(issues, acc_issues)
          do_fetch_issue_states_page(rest_ids, configured_assignee, viewer_login, updated_acc, issue_order_index)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp issue_order_index(ids) when is_list(ids) do
    ids |> Enum.with_index() |> Map.new()
  end

  defp sort_issues_by_requested_ids(issues, issue_order_index)
       when is_list(issues) and is_map(issue_order_index) do
    fallback_index = map_size(issue_order_index)

    Enum.sort_by(issues, fn
      %Issue{id: issue_id} -> Map.get(issue_order_index, issue_id, fallback_index)
      _ -> fallback_index
    end)
  end

  defp build_search_query(repo, state_names, prefix, configured_assignee, viewer_login) do
    parts =
      [
        "repo:" <> repo,
        "is:issue",
        "is:open",
        labels_query_clause(state_names, prefix),
        assignee_query_clause(configured_assignee, viewer_login)
      ]
      |> Enum.reject(&(&1 == ""))

    Enum.join(parts, " ")
  end

  defp labels_query_clause(state_names, prefix) do
    state_names
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> ""
      names -> "label:" <> Enum.map_join(names, ",", &("\"" <> prefix <> slug(&1) <> "\""))
    end
  end

  defp assignee_query_clause(nil, _viewer_login), do: ""

  defp assignee_query_clause(configured, viewer_login) when is_binary(configured) do
    case String.trim(configured) do
      "" -> ""
      "me" -> if is_binary(viewer_login), do: "assignee:" <> viewer_login, else: ""
      other -> "assignee:" <> other
    end
  end

  defp build_graphql_payload(query, variables, operation_name) do
    %{"query" => query, "variables" => variables}
    |> maybe_put_operation_name(operation_name)
  end

  defp maybe_put_operation_name(payload, operation_name) when is_binary(operation_name) do
    trimmed = String.trim(operation_name)
    if trimmed == "", do: payload, else: Map.put(payload, "operationName", trimmed)
  end

  defp maybe_put_operation_name(payload, _operation_name), do: payload

  defp github_error_context(payload, response) when is_map(payload) do
    operation_name =
      case Map.get(payload, "operationName") do
        name when is_binary(name) and name != "" -> " operation=#{name}"
        _ -> ""
      end

    body = response |> Map.get(:body) |> summarize_error_body()
    operation_name <> " body=" <> body
  end

  defp summarize_error_body(body) when is_binary(body) do
    body
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate_error_body()
    |> inspect()
  end

  defp summarize_error_body(body) do
    body
    |> inspect(limit: 20, printable_limit: @max_error_body_log_bytes)
    |> truncate_error_body()
  end

  defp truncate_error_body(body) when is_binary(body) do
    if byte_size(body) > @max_error_body_log_bytes do
      binary_part(body, 0, @max_error_body_log_bytes) <> "...<truncated>"
    else
      body
    end
  end

  defp graphql_headers do
    case resolve_token() do
      {:ok, token} ->
        {:ok,
         [
           {"Authorization", "bearer " <> token},
           {"Content-Type", "application/json"},
           {"User-Agent", "symphony-elixir"},
           {"X-Github-Next-Global-ID", "1"}
         ]}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp post_graphql_request(payload, headers) do
    Req.post(Config.settings!().tracker.endpoint,
      headers: headers,
      json: payload,
      connect_options: [timeout: 30_000]
    )
  end

  defp resolve_token do
    case Application.get_env(:symphony_elixir, :github_resolved_token) do
      token when is_binary(token) ->
        {:ok, token}

      _ ->
        case do_resolve_token() do
          {:ok, token} ->
            Application.put_env(:symphony_elixir, :github_resolved_token, token)
            {:ok, token}

          error ->
            error
        end
    end
  end

  defp do_resolve_token do
    case Config.settings!().tracker.api_key do
      token when is_binary(token) and token != "" ->
        {:ok, token}

      _ ->
        case System.get_env("GH_TOKEN") || System.get_env("GITHUB_TOKEN") do
          token when is_binary(token) and token != "" ->
            {:ok, token}

          _ ->
            resolve_token_via_gh_cli()
        end
    end
  end

  defp resolve_token_via_gh_cli do
    case System.find_executable("gh") do
      nil ->
        {:error, :missing_github_auth}

      path ->
        case System.cmd(path, ["auth", "token"], stderr_to_stdout: true) do
          {output, 0} ->
            case String.trim(output) do
              "" -> {:error, :missing_github_auth}
              token -> {:ok, token}
            end

          _ ->
            {:error, :missing_github_auth}
        end
    end
  end

  defp maybe_resolve_viewer_login(nil), do: {:ok, nil}

  defp maybe_resolve_viewer_login(configured) when is_binary(configured) do
    case String.trim(configured) do
      "me" -> resolve_viewer_login()
      _ -> {:ok, nil}
    end
  end

  defp maybe_resolve_viewer_login(_), do: {:ok, nil}

  defp resolve_viewer_login do
    case Application.get_env(:symphony_elixir, :github_viewer_login) do
      login when is_binary(login) ->
        {:ok, login}

      _ ->
        case graphql(@viewer_query, %{}) do
          {:ok, %{"data" => %{"viewer" => %{"login" => login}}}} when is_binary(login) ->
            Application.put_env(:symphony_elixir, :github_viewer_login, login)
            {:ok, login}

          {:ok, _body} ->
            {:error, :missing_github_viewer_identity}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp decode_search_page_response(
         %{
           "data" => %{
             "search" => %{
               "nodes" => nodes,
               "pageInfo" => %{"hasNextPage" => has_next_page, "endCursor" => end_cursor}
             }
           }
         },
         configured_assignee,
         viewer_login
       )
       when is_list(nodes) do
    issues =
      nodes
      |> Enum.map(&normalize_issue(&1, configured_assignee, viewer_login))
      |> Enum.reject(&is_nil/1)

    {:ok, issues, %{has_next_page: has_next_page == true, end_cursor: end_cursor}}
  end

  defp decode_search_page_response(%{"errors" => errors}, _configured_assignee, _viewer_login) do
    {:error, {:github_graphql_errors, errors}}
  end

  defp decode_search_page_response(_unknown, _configured_assignee, _viewer_login) do
    {:error, :github_unknown_payload}
  end

  defp decode_nodes_response(%{"data" => %{"nodes" => nodes}}, configured_assignee, viewer_login)
       when is_list(nodes) do
    issues =
      nodes
      |> Enum.map(&normalize_issue(&1, configured_assignee, viewer_login))
      |> Enum.reject(&is_nil/1)

    {:ok, issues}
  end

  defp decode_nodes_response(%{"errors" => errors}, _configured_assignee, _viewer_login) do
    {:error, {:github_graphql_errors, errors}}
  end

  defp decode_nodes_response(_unknown, _configured_assignee, _viewer_login) do
    {:error, :github_unknown_payload}
  end

  defp next_page_cursor(%{has_next_page: true, end_cursor: end_cursor})
       when is_binary(end_cursor) and byte_size(end_cursor) > 0 do
    {:ok, end_cursor}
  end

  defp next_page_cursor(%{has_next_page: true}), do: {:error, :github_missing_end_cursor}
  defp next_page_cursor(_), do: :done

  defp normalize_issue(nil, _configured_assignee, _viewer_login), do: nil

  defp normalize_issue(issue, configured_assignee, viewer_login) when is_map(issue) and map_size(issue) > 0 do
    case Map.get(issue, "id") do
      nil ->
        nil

      id when is_binary(id) ->
        number = Map.get(issue, "number")
        title = Map.get(issue, "title")
        labels = extract_labels(issue)
        assignees = extract_assignees(issue)
        derived_state = derive_state(labels, label_prefix())
        effective_state = apply_native_state_override(derived_state, Map.get(issue, "state"), id, number)

        %Issue{
          id: id,
          identifier: identifier_from_number(number),
          title: title,
          description: Map.get(issue, "body"),
          priority: nil,
          state: effective_state,
          branch_name: synthesize_branch_name(number, title),
          url: Map.get(issue, "url"),
          assignee_id: pick_assignee_id(assignees, configured_assignee, viewer_login),
          blocked_by: [],
          labels: labels,
          assigned_to_worker: assigned_to_worker?(assignees, configured_assignee, viewer_login),
          created_at: parse_datetime(Map.get(issue, "createdAt")),
          updated_at: parse_datetime(Map.get(issue, "updatedAt"))
        }
    end
  end

  defp normalize_issue(_issue, _configured_assignee, _viewer_login), do: nil

  defp identifier_from_number(number) when is_integer(number), do: "#" <> Integer.to_string(number)
  defp identifier_from_number(_), do: nil

  defp extract_labels(%{"labels" => %{"nodes" => nodes}}) when is_list(nodes) do
    nodes
    |> Enum.map(& &1["name"])
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&String.downcase/1)
  end

  defp extract_labels(_), do: []

  defp extract_assignees(%{"assignees" => %{"nodes" => nodes}}) when is_list(nodes) do
    nodes
    |> Enum.map(& &1["login"])
    |> Enum.reject(&is_nil/1)
  end

  defp extract_assignees(_), do: []

  defp derive_state(labels, prefix) when is_list(labels) and is_binary(prefix) do
    matching =
      labels
      |> Enum.filter(&String.starts_with?(&1, String.downcase(prefix)))

    case matching do
      [] ->
        nil

      [single] ->
        strip_prefix(single, prefix)

      [first | _rest] ->
        Logger.warning("GitHub issue has multiple #{inspect(prefix)} labels: #{inspect(matching)}; using #{inspect(first)}")

        strip_prefix(first, prefix)
    end
  end

  defp derive_state(_labels, _prefix), do: nil

  defp apply_native_state_override(nil, _native_state, _id, _number), do: nil

  defp apply_native_state_override(derived_state, "CLOSED", id, number)
       when is_binary(derived_state) do
    if active_state?(derived_state) do
      Logger.warning("GitHub issue #{inspect(id)} (##{number}) is CLOSED but carries active status label #{inspect(derived_state)}; treating as terminal")

      nil
    else
      derived_state
    end
  end

  defp apply_native_state_override(derived_state, _native_state, _id, _number), do: derived_state

  defp active_state?(state_name) when is_binary(state_name) do
    normalized = Config.Schema.normalize_issue_state(state_name)

    case Config.settings!() do
      %{tracker: %{active_states: active_states}} when is_list(active_states) ->
        Enum.any?(active_states, fn s ->
          Config.Schema.normalize_issue_state(to_string(s)) == normalized
        end)

      _ ->
        false
    end
  end

  defp strip_prefix(label, prefix) do
    lower_prefix = String.downcase(prefix)

    case String.starts_with?(label, lower_prefix) do
      true -> binary_part(label, byte_size(lower_prefix), byte_size(label) - byte_size(lower_prefix))
      false -> label
    end
  end

  defp label_prefix do
    Config.settings!().tracker.state_label_prefix || "status:"
  end

  defp pick_assignee_id([], _configured_assignee, _viewer_login), do: nil

  defp pick_assignee_id(assignees, configured_assignee, viewer_login) when is_list(assignees) do
    target = resolve_target_login(configured_assignee, viewer_login)

    case target do
      nil -> List.first(assignees)
      login -> Enum.find(assignees, List.first(assignees), &(&1 == login))
    end
  end

  defp assigned_to_worker?(_assignees, nil, _viewer_login), do: true

  defp assigned_to_worker?(assignees, configured_assignee, viewer_login) when is_list(assignees) do
    case resolve_target_login(configured_assignee, viewer_login) do
      nil -> true
      login -> Enum.any?(assignees, &(&1 == login))
    end
  end

  defp assigned_to_worker?(_assignees, _configured_assignee, _viewer_login), do: false

  defp resolve_target_login(nil, _viewer_login), do: nil

  defp resolve_target_login(configured, viewer_login) when is_binary(configured) do
    case String.trim(configured) do
      "" -> nil
      "me" -> viewer_login
      other -> other
    end
  end

  defp resolve_target_login(_configured, _viewer_login), do: nil

  defp parse_datetime(nil), do: nil

  defp parse_datetime(raw) when is_binary(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_datetime(_), do: nil

  defp synthesize_branch_name(number, title) when is_integer(number) do
    base = "symphony/issue-#{number}"
    slugged = title |> to_string() |> slug()

    branch =
      if slugged == "" do
        base
      else
        base <> "-" <> slugged
      end

    truncate(branch, 64)
  end

  defp synthesize_branch_name(_number, _title), do: nil

  defp slug(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp slug(_value), do: ""

  defp truncate(value, max_bytes) when is_binary(value) and is_integer(max_bytes) do
    if byte_size(value) <= max_bytes do
      value
    else
      value
      |> binary_part(0, max_bytes)
      |> String.trim_trailing("-")
    end
  end
end
