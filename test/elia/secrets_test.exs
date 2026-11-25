defmodule Elia.SecretsTest do
  # SECRET-7 reads the API keys Elia holds, and a test that sets one does so in
  # the shared settings database, so this module doesn't run async.
  use ExUnit.Case, async: false

  import Elia.LLMCase

  alias Elia.LLM.Message
  alias Elia.Secrets

  @moduletag :tmp_dir

  defp project(dir), do: %{id: "p", name: "P", folder: dir, harness?: false}

  defp write(dir, text) do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, ".env"), text)
    project(dir)
  end

  defp values(project), do: Enum.map(Secrets.secrets(project), &elem(&1, 0))

  # SECRET-1
  test "reads a project's .env: comments and blanks skipped, quotes off, the last value winning",
       %{tmp_dir: dir} do
    project =
      write(dir, """
      # what this project needs

      STRIPE_SECRET_KEY = "sk_live_abc123"
      export DATABASE_URL='postgres://user:pw@host/db'
      PORT=4000
      not a variable=1
      NO_VALUE
      PORT=5000
      SPACED =  spaced out
      """)

    assert Secrets.variables(project) == [
             {"STRIPE_SECRET_KEY", "sk_live_abc123"},
             {"DATABASE_URL", "postgres://user:pw@host/db"},
             {"PORT", "5000"},
             {"SPACED", "spaced out"}
           ]

    # The place of a name is its first line's, its value the last one's.
    assert Secrets.names(project) == ["STRIPE_SECRET_KEY", "DATABASE_URL", "PORT", "SPACED"]
  end

  # SECRET-2
  test "a project with no .env, an unreadable one and one with no assignment has none", %{
    tmp_dir: dir
  } do
    assert Secrets.variables(project(dir)) == []
    assert Secrets.names(project(dir)) == []
    assert Secrets.names(nil) == []
    assert Secrets.variables(%{}) == []

    # A directory where the file would be is a file that cannot be read.
    unreadable = Path.join(dir, "unreadable")
    File.mkdir_p!(unreadable)
    assert Secrets.read(unreadable) == []

    empty = write(Path.join(dir, "empty"), "# nothing here\n\n   \n")
    assert Secrets.variables(empty) == []

    assert Secrets.secrets(empty) |> Enum.map(&elem(&1, 0)) |> Enum.member?("nothing here") ==
             false
  end

  # SECRET-4
  test "the file is read again every time, so an edit applies at once", %{tmp_dir: dir} do
    project = write(dir, "TOKEN=first_value\n")

    assert Secrets.redact_text("first_value", project) == "[redacted:TOKEN]"

    File.write!(Path.join(dir, ".env"), "TOKEN=second_value\n")

    assert Secrets.redact_text("second_value", project) == "[redacted:TOKEN]"
    assert Secrets.redact_text("first_value", project) == "first_value"
  end

  # SECRET-3: the project's folder decides, never the directory a chat works in
  # (PROJ-3, DEPLOY-28).
  test "the file is the project's own, not the worktree the chat works in", %{tmp_dir: dir} do
    live = Path.join(dir, "live")
    worktree = Path.join(live, "tmp/worktrees/chat1")
    File.mkdir_p!(worktree)
    File.write!(Path.join(live, ".env"), "TOKEN=from_the_live_tree\n")
    File.write!(Path.join(worktree, ".env"), "TOKEN=from_the_worktree\n")

    project = %{id: "harness", name: "Elia", folder: live, harness?: true}

    assert Secrets.variables(project) == [{"TOKEN", "from_the_live_tree"}]
    assert Secrets.redact_text("from_the_live_tree", project) == "[redacted:TOKEN]"
    assert Secrets.redact_text("from_the_worktree", project) == "from_the_worktree"
  end

  # SECRET-6, SECRET-7
  test "a long value and a short one whose name says it is a secret are redacted", %{
    tmp_dir: dir
  } do
    project = write(dir, "PORT=4000\nAPI_KEY=abc123\nLONG_VALUE=abcdefgh\n")

    assert "abcdefgh" in values(project)
    assert "abc123" in values(project)
    refute "4000" in values(project)

    assert Secrets.redact_text("port 4000, key abc123, value abcdefgh", project) ==
             "port 4000, key [redacted:API_KEY], value [redacted:LONG_VALUE]"
  end

  # SECRET-7: an API key Elia holds is a secret whatever its length
  test "an API key Elia holds is redacted whatever its length", %{tmp_dir: dir} do
    reset_settings()
    configure(Elia.LLM.Anthropic, api_key: "sk-ant-1")

    assert {"sk-ant-1", "ANTHROPIC_API_KEY"} in Secrets.secrets(project(dir))

    assert Secrets.redact_text("key sk-ant-1 here", project(dir)) ==
             "key [redacted:ANTHROPIC_API_KEY] here"
  end

  # SECRET-9
  test "of two values that overlap, the longer is redacted whole", %{tmp_dir: dir} do
    project = write(dir, "SHORT_VALUE=abcdefgh\nLONG_VALUE=abcdefghijklmnop\n")

    assert Secrets.redact_text("abcdefghijklmnop", project) == "[redacted:LONG_VALUE]"
    assert Secrets.redact_text("abcdefgh", project) == "[redacted:SHORT_VALUE]"

    assert Secrets.redact_text("abcdefghijklmnop and abcdefgh", project) ==
             "[redacted:LONG_VALUE] and [redacted:SHORT_VALUE]"
  end

  # SECRET-6, SECRET-8, SECRET-10
  test "redacts every part of a request, and leaves the request it was given alone", %{
    tmp_dir: dir
  } do
    project = write(dir, "TOKEN=sk_live_abc123\n")

    request = %{
      system: "the token is sk_live_abc123",
      tools: [
        %{name: "shell", description: "runs sk_live_abc123", input_schema: %{"type" => "object"}}
      ],
      messages: [
        %Message{role: :user, content: [%{type: :text, text: "sk_live_abc123"}]},
        %Message{
          role: :assistant,
          content: [
            %{
              type: :reasoning,
              text: "sk_live_abc123",
              raw: {Elia.LLM.Anthropic, %{"thinking" => "sk_live_abc123"}}
            },
            %{
              type: :tool_call,
              id: "c1",
              name: "shell",
              input: %{"command" => "echo sk_live_abc123"}
            }
          ]
        },
        %Message{
          role: :tool,
          content: [
            %{type: :tool_result, tool_call_id: "c1", content: "sk_live_abc123", is_error: false},
            %{type: :image, media_type: "image/png", data: "sk_live_abc123", path: "shot.png"}
          ]
        }
      ]
    }

    redacted = Secrets.redact(request, project)

    assert redacted.system == "the token is [redacted:TOKEN]"

    assert [%{description: "runs [redacted:TOKEN]", input_schema: %{"type" => "object"}}] =
             redacted.tools

    assert [%Message{content: [%{type: :text, text: "[redacted:TOKEN]"}]}] =
             Enum.take(redacted.messages, 1)

    assert [%Message{content: [reasoning, call]} | _] = Enum.drop(redacted.messages, 1)
    assert reasoning.text == "[redacted:TOKEN]"

    # SECRET-8: an adapter sends its own raw block back as it came (LLM-5), so it
    # is redacted too — otherwise the value would leave inside it.
    assert reasoning.raw == {Elia.LLM.Anthropic, %{"thinking" => "[redacted:TOKEN]"}}
    assert call.input == %{"command" => "echo [redacted:TOKEN]"}

    assert [%Message{content: [result, image]}] = Enum.take(redacted.messages, -1)
    assert result.content == "[redacted:TOKEN]"

    # VISION-8: a picture's own bytes are not text and are left as they are.
    assert image.data == "sk_live_abc123"
    assert image.path == "shot.png"

    # SECRET-10: the request the caller passed in is untouched.
    assert [%Message{content: [%{text: "sk_live_abc123"}]} | _] = request.messages
    assert request.system == "the token is sk_live_abc123"
  end

  # SECRET-11
  test "an encoding of a value is not redacted", %{tmp_dir: dir} do
    project = write(dir, "PASSWORD=p@ss/w0rd+1\n")

    assert Secrets.redact_text("p@ss/w0rd+1", project) == "[redacted:PASSWORD]"

    for encoded <- [
          Base.encode64("p@ss/w0rd+1"),
          URI.encode_www_form("p@ss/w0rd+1"),
          Base.encode16("p@ss/w0rd+1")
        ] do
      assert Secrets.redact_text(encoded, project) == encoded
    end
  end
end
