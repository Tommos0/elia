defmodule Elia.Skills.ImageTest do
  use ExUnit.Case, async: true

  alias Elia.Skills.Image

  @png <<0x89, "PNG\r\n", 0x1A, "\n">> <> "png body"

  setup do
    dir = Path.join(System.tmp_dir!(), "elia-view-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    File.write!(Path.join(dir, "shot.png"), @png)
    {:ok, dir: dir}
  end

  defp tool, do: Enum.find(Image.tools(), &(&1.name == "view_image"))

  # VISION-12, VISION-14: a look reads one file of the chat's workspace and
  # records what it read, which is what the request turns into the picture the
  # model is sent.
  test "a look records the picture it read", %{dir: dir} do
    assert {:ok, message, facts} =
             Elia.Tool.call(tool(), %{"path" => "shot.png"}, %{workspace: dir, vision: true})

    assert message =~ "shot.png"
    assert message =~ "image/png"
    assert facts == %{image: %{path: "shot.png", media_type: "image/png", size: 16}}
  end

  # VISION-13: a look that can't be answered fails with the reason, naming the
  # path — a file that isn't there, isn't an image, is over the bound, or isn't in
  # the workspace at all.
  test "a look that can't be answered says why", %{dir: dir} do
    outside = Path.join(System.tmp_dir!(), "elia-view-out-#{System.unique_integer([:positive])}")
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "secret.png"), @png)
    on_exit(fn -> File.rm_rf!(outside) end)

    File.mkdir_p!(Path.join(dir, "sub.png"))
    File.write!(Path.join(dir, "notes.txt"), "hello")
    File.write!(Path.join(dir, "fake.png"), "not a png at all")
    File.write!(Path.join(dir, "big.png"), @png <> :binary.copy("x", 5 * 1024 * 1024))

    for {path, said} <- [
          {"missing.png", "no file"},
          {"sub.png", "not a regular file"},
          {"notes.txt", "not an image"},
          {"fake.png", "bytes of that format"},
          {"big.png", "5 MB"},
          {"../#{Path.basename(outside)}/secret.png", "not a path in the chat's workspace"},
          {Path.join(outside, "secret.png"), "not a path in the chat's workspace"}
        ] do
      assert {:error, message} =
               Elia.Tool.call(tool(), %{"path" => path}, %{workspace: dir, vision: true})

      assert message =~ said, "#{path} was refused with: #{message}"
      assert message =~ Path.basename(path)
    end
  end

  # VISION-4, VISION-13: a model that accepts no pictures is refused before
  # anything is read, so no path is recorded either.
  test "a look on a model with no vision is refused", %{dir: dir} do
    for ctx <- [%{vision: false}, %{workspace: dir}, %{}] do
      assert {:error, message} =
               Elia.Tool.call(tool(), %{"path" => "shot.png"}, Map.put_new(ctx, :workspace, dir))

      assert message =~ "accepts no pictures"
    end
  end

  # SKILL-1, SKILL-2, SKILL-7: the skill bundles its instructions with the one
  # tool that carries them out.
  test "the skill is one tool with its path" do
    assert Image.name() == "image"
    assert Image.description() =~ "picture"
    assert Image.instructions() =~ "view_image"

    assert [%Elia.Tool{name: "view_image", approval: :never} = tool] = Image.tools()
    assert tool.input_schema["required"] == ["path"]
    assert tool.description =~ "5 MB"
  end
end
