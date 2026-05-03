defmodule SymphonyElixir.Codex.DynamicToolTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.DynamicTool

  test "tool_specs is empty when GitHub is the configured tracker" do
    assert DynamicTool.tool_specs() == []
  end

  test "executing any tool name returns a failure payload listing the supported tool set" do
    response = DynamicTool.execute("not_a_real_tool", %{})

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => ~s(Unsupported dynamic tool: "not_a_real_tool".),
               "supportedTools" => []
             }
           }

    assert response["contentItems"] == [
             %{
               "type" => "inputText",
               "text" => response["output"]
             }
           ]
  end

  test "executing a nil tool name still returns a failure payload" do
    response = DynamicTool.execute(nil, %{})

    assert response["success"] == false
    assert Jason.decode!(response["output"])["error"]["message"] =~ "Unsupported dynamic tool"
  end
end
