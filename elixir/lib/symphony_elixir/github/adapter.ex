defmodule SymphonyElixir.GitHub.Adapter do
  @moduledoc """
  GitHub-backed tracker adapter.
  """

  @behaviour SymphonyElixir.Tracker

  require Logger
  alias SymphonyElixir.{Config, GitHub.Client}

  @add_comment_mutation """
  mutation SymphonyAddComment($subjectId: ID!, $body: String!) {
    addComment(input: {subjectId: $subjectId, body: $body}) {
      clientMutationId
    }
  }
  """

  @issue_labels_query """
  query SymphonyIssueLabels($id: ID!) {
    node(id: $id) {
      ... on Issue {
        id
        repository { id }
        labels(first: 50) { nodes { id name } }
      }
    }
  }
  """

  @label_lookup_query """
  query SymphonyLabelLookup($repositoryId: ID!, $name: String!) {
    node(id: $repositoryId) {
      ... on Repository {
        label(name: $name) { id name }
      }
    }
  }
  """

  @create_label_mutation """
  mutation SymphonyCreateLabel($repositoryId: ID!, $name: String!, $color: String!) {
    createLabel(input: {repositoryId: $repositoryId, name: $name, color: $color}) {
      label { id name }
    }
  }
  """

  @add_labels_mutation """
  mutation SymphonyAddLabels($labelableId: ID!, $labelIds: [ID!]!) {
    addLabelsToLabelable(input: {labelableId: $labelableId, labelIds: $labelIds}) {
      clientMutationId
    }
  }
  """

  @remove_labels_mutation """
  mutation SymphonyRemoveLabels($labelableId: ID!, $labelIds: [ID!]!) {
    removeLabelsFromLabelable(input: {labelableId: $labelableId, labelIds: $labelIds}) {
      clientMutationId
    }
  }
  """

  @default_state_colors %{
    "todo" => "cccccc",
    "in-progress" => "1d76db",
    "human-review" => "5319e7",
    "merging" => "fbca04",
    "rework" => "d93f0b",
    "done" => "0e8a16",
    "cancelled" => "b60205",
    "canceled" => "b60205",
    "closed" => "b60205",
    "duplicate" => "b60205"
  }
  @fallback_color "cccccc"

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues, do: client_module().fetch_candidate_issues()

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states), do: client_module().fetch_issues_by_states(states)

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids), do: client_module().fetch_issue_states_by_ids(issue_ids)

  @doc false
  @spec color_for_label_for_test(String.t()) :: String.t()
  def color_for_label_for_test(label_name), do: color_for_label(label_name)

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    case client_module().graphql(@add_comment_mutation, %{subjectId: issue_id, body: body}) do
      {:ok, %{"errors" => errors}} when is_list(errors) and errors != [] ->
        {:error, {:github_graphql_errors, errors}}

      {:ok, _body} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    prefix = Config.settings!().tracker.state_label_prefix || "status:"
    target_label_name = prefix <> slug(state_name)

    with {:ok, %{repository_id: repository_id, status_label_ids: status_label_ids}} <-
           load_issue_label_state(issue_id, prefix),
         :ok <- maybe_remove_labels(issue_id, status_label_ids),
         {:ok, target_label_id} <- ensure_label(repository_id, target_label_name) do
      add_labels(issue_id, [target_label_id])
    end
  end

  defp client_module do
    Application.get_env(:symphony_elixir, :github_client_module, Client)
  end

  defp load_issue_label_state(issue_id, prefix) do
    case client_module().graphql(@issue_labels_query, %{id: issue_id}) do
      {:ok, %{"data" => %{"node" => %{"repository" => %{"id" => repository_id}, "labels" => %{"nodes" => label_nodes}}}}}
      when is_binary(repository_id) and is_list(label_nodes) ->
        status_label_ids = collect_status_label_ids(label_nodes, prefix)

        if length(status_label_ids) > 1 do
          Logger.warning("GitHub issue #{issue_id} has multiple status labels: #{inspect(status_label_ids)}; removing all before applying new state")
        end

        {:ok, %{repository_id: repository_id, status_label_ids: status_label_ids}}

      {:ok, %{"errors" => errors}} when is_list(errors) and errors != [] ->
        {:error, {:github_graphql_errors, errors}}

      {:ok, _other} ->
        {:error, :github_issue_not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp collect_status_label_ids(label_nodes, prefix) do
    lower_prefix = String.downcase(prefix)

    label_nodes
    |> Enum.filter(fn
      %{"name" => name} when is_binary(name) -> String.starts_with?(String.downcase(name), lower_prefix)
      _ -> false
    end)
    |> Enum.map(& &1["id"])
    |> Enum.reject(&is_nil/1)
  end

  defp maybe_remove_labels(_issue_id, []), do: :ok

  defp maybe_remove_labels(issue_id, label_ids) do
    case client_module().graphql(@remove_labels_mutation, %{labelableId: issue_id, labelIds: label_ids}) do
      {:ok, %{"errors" => errors}} when is_list(errors) and errors != [] ->
        {:error, {:github_graphql_errors, errors}}

      {:ok, _body} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp add_labels(issue_id, label_ids) do
    case client_module().graphql(@add_labels_mutation, %{labelableId: issue_id, labelIds: label_ids}) do
      {:ok, %{"errors" => errors}} when is_list(errors) and errors != [] ->
        {:error, {:github_graphql_errors, errors}}

      {:ok, _body} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_label(repository_id, label_name) do
    case lookup_label(repository_id, label_name) do
      {:ok, label_id} when is_binary(label_id) ->
        {:ok, label_id}

      {:ok, nil} ->
        create_label(repository_id, label_name)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp lookup_label(repository_id, label_name) do
    case client_module().graphql(@label_lookup_query, %{repositoryId: repository_id, name: label_name}) do
      {:ok, %{"data" => %{"node" => %{"label" => %{"id" => label_id}}}}} when is_binary(label_id) ->
        {:ok, label_id}

      {:ok, %{"data" => %{"node" => %{"label" => nil}}}} ->
        {:ok, nil}

      {:ok, %{"errors" => errors}} when is_list(errors) and errors != [] ->
        {:error, {:github_graphql_errors, errors}}

      {:ok, _other} ->
        {:ok, nil}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_label(repository_id, label_name) do
    color = color_for_label(label_name)
    vars = %{repositoryId: repository_id, name: label_name, color: color}

    case client_module().graphql(@create_label_mutation, vars) do
      {:ok, %{"data" => %{"createLabel" => %{"label" => %{"id" => label_id}}}}} when is_binary(label_id) ->
        {:ok, label_id}

      {:ok, %{"errors" => errors}} when is_list(errors) and errors != [] ->
        {:error, {:github_graphql_errors, errors}}

      {:ok, _other} ->
        {:error, :github_label_create_failed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp color_for_label(label_name) do
    prefix = Config.settings!().tracker.state_label_prefix || "status:"
    lower_prefix = String.downcase(prefix)
    lower_name = String.downcase(label_name)

    state_key =
      if String.starts_with?(lower_name, lower_prefix) do
        binary_part(lower_name, byte_size(lower_prefix), byte_size(lower_name) - byte_size(lower_prefix))
      else
        lower_name
      end

    Map.get(@default_state_colors, state_key, @fallback_color)
  end

  defp slug(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end
end
