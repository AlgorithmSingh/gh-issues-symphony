defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.

  GitHub-backed Symphony has no dynamic tools — agents talk to GitHub via the
  `gh` CLI inside their workspace. This module is kept as a stable seam in case
  another tracker backend reintroduces dynamic tools later.
  """

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, _arguments, _opts \\ []) do
    failure_response(%{
      "error" => %{
        "message" => "Unsupported dynamic tool: #{inspect(tool)}.",
        "supportedTools" => supported_tool_names()
      }
    })
  end

  @spec tool_specs() :: [map()]
  def tool_specs, do: []

  defp failure_response(payload) do
    output = encode_payload(payload)

    %{
      "success" => false,
      "output" => output,
      "contentItems" => [%{"type" => "inputText", "text" => output}]
    }
  end

  defp encode_payload(payload) when is_map(payload) or is_list(payload) do
    Jason.encode!(payload, pretty: true)
  end

  defp encode_payload(payload), do: inspect(payload)

  defp supported_tool_names, do: Enum.map(tool_specs(), & &1["name"])
end
