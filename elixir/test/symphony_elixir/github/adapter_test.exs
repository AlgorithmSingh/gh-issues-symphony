defmodule SymphonyElixir.GitHub.AdapterTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitHub.Adapter

  defmodule FakeClient do
    def fetch_candidate_issues do
      send(self(), :fetch_candidate_issues_called)
      {:ok, []}
    end

    def fetch_issues_by_states(states) do
      send(self(), {:fetch_issues_by_states_called, states})
      {:ok, states}
    end

    def fetch_issue_states_by_ids(ids) do
      send(self(), {:fetch_issue_states_by_ids_called, ids})
      {:ok, ids}
    end

    def graphql(query, variables) do
      send(self(), {:graphql_called, query, variables})

      case Process.get({__MODULE__, :graphql_results}) do
        [result | rest] ->
          Process.put({__MODULE__, :graphql_results}, rest)
          result

        _ ->
          Process.get({__MODULE__, :graphql_result})
      end
    end
  end

  setup do
    previous = Application.get_env(:symphony_elixir, :github_client_module)
    Application.put_env(:symphony_elixir, :github_client_module, FakeClient)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:symphony_elixir, :github_client_module)
      else
        Application.put_env(:symphony_elixir, :github_client_module, previous)
      end
    end)

    :ok
  end

  test "create_comment posts addComment with subjectId and body" do
    Process.put({FakeClient, :graphql_result}, {:ok, %{"data" => %{"addComment" => %{"clientMutationId" => nil}}}})

    assert :ok = Adapter.create_comment("I_kwDO123", "hello world")

    assert_received {:graphql_called, mutation, %{subjectId: "I_kwDO123", body: "hello world"}}
    assert mutation =~ "addComment"
  end

  test "create_comment surfaces graphql errors" do
    Process.put({FakeClient, :graphql_result}, {:ok, %{"errors" => [%{"message" => "boom"}]}})

    assert {:error, {:github_graphql_errors, _}} = Adapter.create_comment("I_kwDO123", "boom")
  end

  test "create_comment surfaces transport errors" do
    Process.put({FakeClient, :graphql_result}, {:error, :network_error})

    assert {:error, :network_error} = Adapter.create_comment("I_kwDO123", "boom")
  end

  test "update_issue_state removes existing status labels in order before adding the new label" do
    Process.put(
      {FakeClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "node" => %{
               "id" => "I_kwDO123",
               "repository" => %{"id" => "R_kw1"},
               "labels" => %{
                 "nodes" => [
                   %{"id" => "L_old", "name" => "status:todo"},
                   %{"id" => "L_other", "name" => "bug"}
                 ]
               }
             }
           }
         }},
        {:ok, %{"data" => %{"removeLabelsFromLabelable" => %{"clientMutationId" => nil}}}},
        {:ok, %{"data" => %{"node" => %{"label" => %{"id" => "L_new"}}}}},
        {:ok, %{"data" => %{"addLabelsToLabelable" => %{"clientMutationId" => nil}}}}
      ]
    )

    assert :ok = Adapter.update_issue_state("I_kwDO123", "In Progress")

    assert_receive {:graphql_called, _read, %{id: "I_kwDO123"}}
    assert_receive {:graphql_called, _remove, %{labelableId: "I_kwDO123", labelIds: ["L_old"]}}
    assert_receive {:graphql_called, _lookup, %{repositoryId: "R_kw1", name: "status:in-progress"}}
    assert_receive {:graphql_called, _add, %{labelableId: "I_kwDO123", labelIds: ["L_new"]}}
  end

  test "update_issue_state removes every status label when there are duplicates and warns" do
    Process.put(
      {FakeClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "node" => %{
               "id" => "I_kwDO456",
               "repository" => %{"id" => "R_kw1"},
               "labels" => %{
                 "nodes" => [
                   %{"id" => "L_a", "name" => "status:todo"},
                   %{"id" => "L_b", "name" => "status:in-progress"}
                 ]
               }
             }
           }
         }},
        {:ok, %{"data" => %{"removeLabelsFromLabelable" => %{"clientMutationId" => nil}}}},
        {:ok, %{"data" => %{"node" => %{"label" => %{"id" => "L_done"}}}}},
        {:ok, %{"data" => %{"addLabelsToLabelable" => %{"clientMutationId" => nil}}}}
      ]
    )

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok = Adapter.update_issue_state("I_kwDO456", "Done")
      end)

    assert log =~ "multiple status labels"
    assert_receive {:graphql_called, _read, %{id: "I_kwDO456"}}
    assert_receive {:graphql_called, _remove, %{labelableId: "I_kwDO456", labelIds: ["L_a", "L_b"]}}
  end

  test "update_issue_state creates the label on demand when none exists in the repo" do
    Process.put(
      {FakeClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "node" => %{
               "id" => "I_kwDO789",
               "repository" => %{"id" => "R_kw9"},
               "labels" => %{"nodes" => []}
             }
           }
         }},
        {:ok, %{"data" => %{"node" => %{"label" => nil}}}},
        {:ok, %{"data" => %{"createLabel" => %{"label" => %{"id" => "L_new"}}}}},
        {:ok, %{"data" => %{"addLabelsToLabelable" => %{"clientMutationId" => nil}}}}
      ]
    )

    assert :ok = Adapter.update_issue_state("I_kwDO789", "Human Review")

    assert_receive {:graphql_called, _read, %{id: "I_kwDO789"}}
    assert_receive {:graphql_called, _lookup, %{repositoryId: "R_kw9", name: "status:human-review"}}
    assert_receive {:graphql_called, create_query, %{repositoryId: "R_kw9", name: "status:human-review", color: "5319e7"}}
    assert create_query =~ "createLabel"
    assert_receive {:graphql_called, _add, %{labelableId: "I_kwDO789", labelIds: ["L_new"]}}
  end

  test "update_issue_state surfaces transport errors before mutating labels" do
    Process.put({FakeClient, :graphql_results}, [{:error, :boom}])

    assert {:error, :boom} = Adapter.update_issue_state("I_kwDO111", "Done")
  end

  test "update_issue_state surfaces graphql errors when reading labels" do
    Process.put(
      {FakeClient, :graphql_results},
      [{:ok, %{"errors" => [%{"message" => "Could not resolve"}]}}]
    )

    assert {:error, {:github_graphql_errors, _}} = Adapter.update_issue_state("I_kwDO111", "Done")
  end

  test "update_issue_state returns not found when issue label payload is unexpected" do
    Process.put({FakeClient, :graphql_results}, [{:ok, %{"data" => nil}}])

    assert {:error, :github_issue_not_found} = Adapter.update_issue_state("I_kwDO222", "Done")
  end

  test "update_issue_state ignores malformed label nodes and surfaces remove graphql errors" do
    Process.put(
      {FakeClient, :graphql_results},
      [
        issue_labels_response([
          %{"id" => "L_old", "name" => "status:todo"},
          %{"id" => "L_missing_name"},
          %{"id" => "L_non_binary_name", "name" => 42},
          %{"id" => "L_other", "name" => "bug"}
        ]),
        {:ok, %{"errors" => [%{"message" => "remove failed"}]}}
      ]
    )

    assert {:error, {:github_graphql_errors, [%{"message" => "remove failed"}]}} =
             Adapter.update_issue_state("I_kwDO222", "Done")

    assert_receive {:graphql_called, _read, %{id: "I_kwDO222"}}
    assert_receive {:graphql_called, _remove, %{labelableId: "I_kwDO222", labelIds: ["L_old"]}}
  end

  test "update_issue_state surfaces remove transport errors" do
    Process.put(
      {FakeClient, :graphql_results},
      [
        issue_labels_response([%{"id" => "L_old", "name" => "status:todo"}]),
        {:error, :network_error}
      ]
    )

    assert {:error, :network_error} = Adapter.update_issue_state("I_kwDO333", "Done")
  end

  test "update_issue_state surfaces add graphql errors" do
    Process.put(
      {FakeClient, :graphql_results},
      [
        issue_labels_response([]),
        existing_label_response("L_done"),
        {:ok, %{"errors" => [%{"message" => "add failed"}]}}
      ]
    )

    assert {:error, {:github_graphql_errors, [%{"message" => "add failed"}]}} =
             Adapter.update_issue_state("I_kwDO444", "Done")

    assert_receive {:graphql_called, _add, %{labelableId: "I_kwDO444", labelIds: ["L_done"]}}
  end

  test "update_issue_state surfaces add transport errors" do
    Process.put(
      {FakeClient, :graphql_results},
      [issue_labels_response([]), existing_label_response("L_done"), {:error, :add_down}]
    )

    assert {:error, :add_down} = Adapter.update_issue_state("I_kwDO555", "Done")
  end

  test "update_issue_state surfaces lookup transport errors" do
    Process.put({FakeClient, :graphql_results}, [issue_labels_response([]), {:error, :lookup_down}])

    assert {:error, :lookup_down} = Adapter.update_issue_state("I_kwDO666", "Done")
  end

  test "update_issue_state surfaces lookup graphql errors" do
    Process.put(
      {FakeClient, :graphql_results},
      [
        issue_labels_response([]),
        {:ok, %{"errors" => [%{"message" => "lookup failed"}]}}
      ]
    )

    assert {:error, {:github_graphql_errors, [%{"message" => "lookup failed"}]}} =
             Adapter.update_issue_state("I_kwDO777", "Done")
  end

  test "update_issue_state treats unexpected lookup bodies as missing labels" do
    Process.put(
      {FakeClient, :graphql_results},
      [
        issue_labels_response([]),
        {:ok, %{"data" => nil}},
        {:ok, %{"data" => %{"createLabel" => %{"label" => %{"name" => "status:done"}}}}}
      ]
    )

    assert {:error, :github_label_create_failed} = Adapter.update_issue_state("I_kwDO888", "Done")
  end

  test "update_issue_state surfaces create label graphql errors" do
    Process.put(
      {FakeClient, :graphql_results},
      [
        issue_labels_response([]),
        missing_label_response(),
        {:ok, %{"errors" => [%{"message" => "create failed"}]}}
      ]
    )

    assert {:error, {:github_graphql_errors, [%{"message" => "create failed"}]}} =
             Adapter.update_issue_state("I_kwDO999", "Done")
  end

  test "update_issue_state surfaces create label transport errors" do
    Process.put(
      {FakeClient, :graphql_results},
      [issue_labels_response([]), missing_label_response(), {:error, :transport_failure}]
    )

    assert {:error, :transport_failure} = Adapter.update_issue_state("I_kwDO000", "Done")
  end

  test "color_for_label_for_test handles label names without the configured prefix" do
    assert Adapter.color_for_label_for_test("done") == "0e8a16"
    assert Adapter.color_for_label_for_test("unknown-state") == "cccccc"
  end

  defp issue_labels_response(nodes) do
    {:ok,
     %{
       "data" => %{
         "node" => %{
           "id" => "I_kwDO123",
           "repository" => %{"id" => "R_kw1"},
           "labels" => %{"nodes" => nodes}
         }
       }
     }}
  end

  defp existing_label_response(label_id) do
    {:ok, %{"data" => %{"node" => %{"label" => %{"id" => label_id}}}}}
  end

  defp missing_label_response do
    {:ok, %{"data" => %{"node" => %{"label" => nil}}}}
  end
end
