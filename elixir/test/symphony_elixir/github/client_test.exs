defmodule SymphonyElixir.GitHub.ClientTest do
  use SymphonyElixir.TestSupport

  setup do
    Client.reset_memoized_token_for_test()

    on_exit(fn ->
      Client.reset_memoized_token_for_test()
    end)

    :ok
  end

  describe "build_search_query_for_test/5" do
    test "joins repo, is:issue, is:open, and OR-ed labels with the configured prefix" do
      query =
        Client.build_search_query_for_test(
          "owner/name",
          ["Todo", "In Progress"],
          "status:",
          nil,
          nil
        )

      assert query == ~s(repo:owner/name is:issue is:open label:"status:todo","status:in-progress")
    end

    test "appends assignee:<login> when configured" do
      query =
        Client.build_search_query_for_test("owner/name", ["Todo"], "status:", "octocat", nil)

      assert query =~ "assignee:octocat"
    end

    test "appends viewer login when assignee is 'me'" do
      query =
        Client.build_search_query_for_test("owner/name", ["Todo"], "status:", "me", "octocat")

      assert query =~ "assignee:octocat"
    end

    test "omits assignee clause when 'me' is configured but viewer is unknown" do
      query =
        Client.build_search_query_for_test("owner/name", ["Todo"], "status:", "me", nil)

      refute query =~ "assignee:"
    end

    test "skips empty state names" do
      query = Client.build_search_query_for_test("owner/name", ["", "Todo"], "status:", nil, nil)

      assert query == ~s(repo:owner/name is:issue is:open label:"status:todo")
    end
  end

  describe "normalize_issue_for_test/3" do
    test "derives state from a single status:* label and lowercases all label names" do
      raw = sample_issue_payload()

      issue = Client.normalize_issue_for_test(raw, nil, nil)

      assert issue.id == "I_kwDO000001"
      assert issue.identifier == "#142"
      assert issue.state == "todo"
      assert issue.labels == ["status:todo", "frontend"]
      assert issue.priority == nil
      assert issue.url == "https://github.com/owner/name/issues/142"
      assert issue.assignee_id == "octocat"
      assert issue.assigned_to_worker
      assert %DateTime{} = issue.created_at
      assert %DateTime{} = issue.updated_at
    end

    test "returns nil state when no status:* label exists" do
      raw =
        sample_issue_payload()
        |> put_in(["labels"], %{"nodes" => [%{"name" => "frontend"}]})

      issue = Client.normalize_issue_for_test(raw, nil, nil)

      assert issue.state == nil
    end

    test "logs a warning and picks the first status:* label when several are present" do
      raw =
        sample_issue_payload()
        |> put_in(["labels"], %{
          "nodes" => [
            %{"name" => "status:todo"},
            %{"name" => "status:in-progress"}
          ]
        })

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          issue = Client.normalize_issue_for_test(raw, nil, nil)
          assert issue.state == "todo"
        end)

      assert log =~ "multiple"
    end

    test "marks issues as not routed when configured assignee does not match any login" do
      raw =
        sample_issue_payload()
        |> put_in(["assignees"], %{"nodes" => [%{"login" => "alice"}]})

      issue = Client.normalize_issue_for_test(raw, "bob", nil)

      refute issue.assigned_to_worker
    end

    test "resolves 'me' to the supplied viewer login" do
      raw =
        sample_issue_payload()
        |> put_in(["assignees"], %{"nodes" => [%{"login" => "octocat"}]})

      issue = Client.normalize_issue_for_test(raw, "me", "octocat")

      assert issue.assigned_to_worker
      assert issue.assignee_id == "octocat"
    end

    test "always treats issues as routable when no assignee is configured" do
      raw =
        sample_issue_payload()
        |> put_in(["assignees"], %{"nodes" => []})

      issue = Client.normalize_issue_for_test(raw, nil, nil)

      assert issue.assigned_to_worker
    end
  end

  describe "branch_name_for_test/2" do
    test "synthesizes a slugified branch from issue number and title" do
      assert Client.branch_name_for_test(142, "Add login button") ==
               "symphony/issue-142-add-login-button"
    end

    test "truncates branch names to 64 bytes" do
      title =
        "make extremely long branch names get safely truncated for git refs"

      branch = Client.branch_name_for_test(142, title)
      assert byte_size(branch) <= 64
      assert String.starts_with?(branch, "symphony/issue-142-")
      refute String.ends_with?(branch, "-")
    end

    test "falls back to the bare prefix when title has no slug-safe characters" do
      assert Client.branch_name_for_test(7, "🎉🎉🎉") == "symphony/issue-7"
    end
  end

  describe "slug_for_test/1" do
    test "lowercases and dash-separates non-alphanumerics" do
      assert Client.slug_for_test("In Progress") == "in-progress"
      assert Client.slug_for_test("Human Review") == "human-review"
    end

    test "strips leading and trailing dashes" do
      assert Client.slug_for_test("-todo-") == "todo"
    end
  end

  describe "resolve_token_for_test/0" do
    test "returns the configured api_key when present" do
      previous_gh_token = System.get_env("GH_TOKEN")
      previous_github_token = System.get_env("GITHUB_TOKEN")

      on_exit(fn ->
        restore_env("GH_TOKEN", previous_gh_token)
        restore_env("GITHUB_TOKEN", previous_github_token)
      end)

      System.delete_env("GH_TOKEN")
      System.delete_env("GITHUB_TOKEN")
      Client.reset_memoized_token_for_test()

      write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: "from-config")

      assert {:ok, "from-config"} = Client.resolve_token_for_test()
    end

    test "falls back to GH_TOKEN env var when api_key is unset" do
      previous_gh_token = System.get_env("GH_TOKEN")
      previous_github_token = System.get_env("GITHUB_TOKEN")

      on_exit(fn ->
        restore_env("GH_TOKEN", previous_gh_token)
        restore_env("GITHUB_TOKEN", previous_github_token)
      end)

      System.delete_env("GITHUB_TOKEN")
      System.put_env("GH_TOKEN", "from-env")

      write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: nil)
      Client.reset_memoized_token_for_test()

      assert {:ok, env_token} = Client.resolve_token_for_test()
      assert env_token == "from-env"
    end

    test "memoizes the resolved token" do
      previous_gh_token = System.get_env("GH_TOKEN")
      previous_github_token = System.get_env("GITHUB_TOKEN")

      on_exit(fn ->
        restore_env("GH_TOKEN", previous_gh_token)
        restore_env("GITHUB_TOKEN", previous_github_token)
      end)

      System.delete_env("GITHUB_TOKEN")
      System.put_env("GH_TOKEN", "first-token")

      write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: nil)
      Client.reset_memoized_token_for_test()

      assert {:ok, "first-token"} = Client.resolve_token_for_test()

      System.put_env("GH_TOKEN", "second-token")

      assert {:ok, "first-token"} = Client.resolve_token_for_test()
    end
  end

  describe "graphql/3" do
    test "logs response bodies for non-200 graphql responses" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, {:github_api_status, 400}} =
                   Client.graphql(
                     "query Viewer { viewer { login } }",
                     %{},
                     request_fun: fn _payload, _headers ->
                       {:ok,
                        %{
                          status: 400,
                          body: %{
                            "errors" => [
                              %{
                                "message" => "Variable \"$ids\" got invalid value",
                                "extensions" => %{"code" => "BAD_USER_INPUT"}
                              }
                            ]
                          }
                        }}
                     end
                   )
        end)

      assert log =~ "GitHub GraphQL request failed status=400"
      assert log =~ "BAD_USER_INPUT"
    end

    test "wraps transport failures with the github_api_request tag" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, {:github_api_request, :timeout}} =
                   Client.graphql(
                     "query Viewer { viewer { login } }",
                     %{},
                     request_fun: fn _payload, _headers -> {:error, :timeout} end
                   )
        end)

      assert log =~ "GitHub GraphQL request failed"
    end

    test "sends bearer auth and the next-global-id header" do
      assert {:ok, %{}} =
               Client.graphql(
                 "query Viewer { viewer { login } }",
                 %{},
                 request_fun: fn _payload, headers ->
                   send(self(), {:headers_observed, headers})
                   {:ok, %{status: 200, body: %{}}}
                 end
               )

      assert_received {:headers_observed, headers}
      assert {"Authorization", "bearer token"} in headers
      assert {"X-Github-Next-Global-ID", "1"} in headers
    end
  end

  defp sample_issue_payload do
    %{
      "id" => "I_kwDO000001",
      "number" => 142,
      "title" => "Add login button",
      "body" => "Add a sign-in button to the navbar.",
      "url" => "https://github.com/owner/name/issues/142",
      "state" => "OPEN",
      "createdAt" => "2026-01-01T12:00:00Z",
      "updatedAt" => "2026-01-02T08:30:00Z",
      "repository" => %{"nameWithOwner" => "owner/name"},
      "assignees" => %{"nodes" => [%{"login" => "octocat"}]},
      "labels" => %{
        "nodes" => [
          %{"name" => "status:todo"},
          %{"name" => "Frontend"}
        ]
      }
    }
  end
end
