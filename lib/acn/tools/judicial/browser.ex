defmodule ACN.Tools.Judicial.Browser do
  @behaviour ACN.Tools.ToolBehaviour

  @impl true
  def definition do
    %{
      "name" => "judicial_browser",
      "description" => "Controls a persistent Playwright browser for the current review, including navigation, page JavaScript evaluation, DOM inspection and actions, and screenshots. Screenshots are returned as visual input for the model.",
      "parameters" => %{
        "type" => "object",
        "properties" => %{
          "action" => %{"type" => "string", "description" => "Browser action."},
          "url" => %{"type" => "string"},
          "selector" => %{"type" => "string"},
          "ref" => %{"type" => "string", "description" => "Accessible element reference from an AI-mode snapshot."},
          "value" => %{"type" => "string"},
          "key" => %{"type" => "string"},
          "wait_ms" => %{"type" => "integer"},
          "full_page" => %{"type" => "boolean"},
          "expression" => %{"type" => "string", "description" => "JavaScript expression for evaluate."},
          "target" => %{"type" => "string", "description" => "Playwright target: page, locator, context, or browser."},
          "method" => %{"type" => "string", "description" => "Playwright method name for the playwright action."},
          "call_args" => %{"type" => "array", "description" => "Arguments passed to the Playwright method."},
          "nth" => %{"type" => "integer", "description" => "Optional locator index."}
        },
        "required" => ["action"]
      }
    }
  end

  @impl true
  def execute(args, env) do
    session_id = to_string(env[:node_id] || "root")

    case ACN.JudicialBrowser.execute(session_id, args) do
      {:ok, result} ->
        text = result["text"] || "Browser action completed."
        content = [%{"type" => "text", "text" => text}]

        content =
          case result["screenshot_base64"] do
            image when is_binary(image) and image != "" ->
              content ++ [
                %{
                  "type" => "image_url",
                  "image_url" => %{
                    "url" => "data:image/jpeg;base64," <> image,
                    "detail" => "high"
                  }
                }
              ]

            _ -> content
          end

        {:ok, content}

      {:error, reason} -> {:error, "Browser action failed: #{reason}"}
    end
  end
end
