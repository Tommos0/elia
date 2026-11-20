defmodule Elia.LLM.ImagesTest do
  use ExUnit.Case, async: true

  alias Elia.LLM.Images
  alias Elia.LLM.Message

  @png <<0x89, "PNG\r\n", 0x1A, "\n">> <> "png body"
  @jpeg <<0xFF, 0xD8, 0xFF>> <> "jpeg body"
  @gif "GIF89a" <> "gif body"
  @webp "RIFF" <> <<0, 0, 0, 0>> <> "WEBP" <> "webp body"

  setup do
    dir = Path.join(System.tmp_dir!(), "elia-images-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  defp write(dir, name, content) do
    File.write!(Path.join(dir, name), content)
    name
  end

  # VISION-2: the extension names the format, whatever its case, and only the
  # formats both APIs accept.
  test "a file is an image by its extension, whatever the case" do
    assert Images.media_type("uploads/shot.png") == "image/png"
    assert Images.media_type("a.JPG") == "image/jpeg"
    assert Images.media_type("a.jpeg") == "image/jpeg"
    assert Images.media_type("a.WebP") == "image/webp"
    assert Images.media_type("a.gif") == "image/gif"
    assert Images.media_type("notes.txt") == nil
    assert Images.media_type("photo.heic") == nil
    assert Images.media_type("no-extension") == nil
  end

  # VISION-3: a picture is read from the chat's workspace as the request is
  # built, and the block carries the file's own bytes and its media type.
  test "read reads a picture from the workspace", %{dir: dir} do
    write(dir, "shot.png", @png)

    assert {:ok, block} = Images.read(dir, "shot.png")

    assert %{type: :image, media_type: "image/png", path: "shot.png", size: 16} = block
    assert Base.decode64!(block.data) == @png

    # The bytes are the file's own; nothing was written or converted.
    assert File.read!(Path.join(dir, "shot.png")) == @png
  end

  # VISION-2: the bytes must be the format the extension names, since the media
  # type sent to a provider would be wrong for them. VISION-3: the second is the
  # path the look named.
  test "a file whose bytes aren't the format its extension names is not an image", %{dir: dir} do
    write(dir, "fake.png", "just text")
    write(dir, "notes.png", "")
    write(dir, "shot.jpg", @png)

    assert Images.read(dir, "fake.png") == {:error, :not_an_image}
    assert Images.read(dir, "notes.png") == {:error, :not_an_image}
    assert Images.read(dir, "shot.jpg") == {:error, :not_an_image}

    # A JPEG that is one, and a WebP whose RIFF body is a WAV, both by signature.
    write(dir, "real.jpg", @jpeg)
    assert {:ok, %{media_type: "image/jpeg"}} = Images.read(dir, "real.jpg")

    write(dir, "sound.webp", "RIFF" <> <<0, 0, 0, 0>> <> "WAVE" <> "data")
    assert Images.read(dir, "sound.webp") == {:error, :not_an_image}
  end

  test "the other formats' signatures are recognised", %{dir: dir} do
    assert {:ok, %{media_type: "image/gif"}} = Images.read(dir, write(dir, "a.gif", @gif))
    assert {:ok, %{media_type: "image/webp"}} = Images.read(dir, write(dir, "a.webp", @webp))
  end

  # VISION-5: a look that can't be read is skipped rather than failing the turn —
  # a file that isn't there, one that isn't a regular file, a path that leaves the
  # workspace, and a path that leaves it through a symlink.
  test "a picture that can't be read is skipped", %{dir: dir} do
    outside =
      Path.join(System.tmp_dir!(), "elia-images-out-#{System.unique_integer([:positive])}")

    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "secret.png"), @png)
    on_exit(fn -> File.rm_rf!(outside) end)

    File.mkdir_p!(Path.join(dir, "adir.png"))

    assert Images.load(dir, "adir.png") == :skip
    assert Images.load(dir, "missing.png") == :skip
    assert Images.load(dir, "../#{Path.basename(outside)}/secret.png") == :skip
    assert Images.load(dir, Path.join(outside, "secret.png")) == :skip
    assert Images.load(dir, nil) == :skip

    # Each of them says which it was, so a look can say why (VISION-13).
    assert Images.read(dir, "missing.png") == {:error, :not_found}
    assert Images.read(dir, "adir.png") == {:error, :not_a_file}
    assert Images.read(dir, "adir") == {:error, :not_an_image}
    assert Images.read(dir, Path.join(outside, "secret.png")) == {:error, :forbidden}

    File.ln_s!(Path.join(outside, "secret.png"), Path.join(dir, "link.png"))
    assert Images.load(dir, "link.png") == :skip
    assert Images.read(dir, "link.png") == {:error, :forbidden}
  end

  # VISION-6: one picture is bounded, and so is what one request carries.
  test "a picture over a bound is not sent", %{dir: dir} do
    big = @png <> :binary.copy("x", 5 * 1024 * 1024)
    write(dir, "big.png", big)

    assert byte_size(big) > 5 * 1024 * 1024
    assert Images.load(dir, "big.png") == {:error, :too_large}
    assert Images.read(dir, "big.png") == {:error, :too_large}

    # The room a request has left bounds it too.
    assert Images.load(dir, "big.png", 10) == {:error, :too_large}
    assert Images.read(dir, "big.png", 10) == {:error, :too_large}
  end

  # VISION-12, VISION-14: a tool result that recorded a look carries its picture
  # itself, after the result's own block — and VISION-15: nothing of it is stored,
  # so the history the request was built from keeps the path and no picture.
  test "attach puts a look's picture in the result's own message", %{dir: dir} do
    write(dir, "shot.png", @png)

    history = [Message.user("look at it"), call("c1", "shot.png"), looked_at("c1", "shot.png")]
    [user, call, tool] = Images.attach(history, dir, true)

    assert Enum.map(user.content, & &1.type) == [:text]
    assert Enum.map(call.content, & &1.type) == [:tool_call]
    assert [%{type: :tool_result}, picture] = tool.content
    assert %{type: :image, media_type: "image/png", path: "shot.png"} = picture
    assert Base.decode64!(picture.data) == @png

    # The picture travels with that result and no other message.
    refute Enum.any?(user.content, &(&1.type == :image))

    # VISION-15: the saved chat's own block is untouched — the path it recorded
    # is all there is of it, and a reload reads the file again (VISION-9).
    assert [%{type: :tool_result} = saved] = Enum.at(history, 2).content
    assert saved.image == %{path: "shot.png", media_type: "image/png", size: 16}
    refute Map.has_key?(saved, :data)
  end

  # VISION-5: a look whose file can't be read sends nothing and keeps the path it
  # recorded, and a message that looked at nothing is left exactly as it was.
  test "attach leaves a result whose picture can't be read alone", %{dir: dir} do
    nothing = Message.tool_result("c1", "ran it")
    looked = looked_at("c2", "gone.png")

    history = [
      Message.user("go"),
      call("c1", nil),
      %Message{role: :tool, content: [nothing]},
      call("c2", "gone.png"),
      %Message{role: :tool, content: [looked]}
    ]

    assert Images.attach(history, dir, true) == history
  end

  # VISION-4, VISION-9: a model that accepts no pictures is sent the messages as
  # they are, and the picture of a look is read again on every request that still
  # holds its result.
  test "attach sends nothing to a model that accepts no pictures", %{dir: dir} do
    write(dir, "shot.png", @png)
    history = [call("c1", "shot.png"), looked_at("c1", "shot.png")]

    assert Images.attach(history, dir, false) == history

    # Read again for the second request, from the file as it is now.
    [first] = Images.attach(history, dir, true) |> Enum.take(-1)
    write(dir, "shot.png", @png <> "and more")
    [%Message{content: [_, again]}] = Images.attach(history, dir, true) |> Enum.take(-1)
    assert Base.decode64!(again.data) == @png <> "and more"
    assert byte_size(Base.decode64!(first.content |> List.last() |> Map.fetch!(:data))) == 16
  end

  # VISION-6: the pictures one request carries are bounded from the newest message
  # first, so the one the agent has just looked at is sent before an older one.
  test "the newest message's pictures are taken first", %{dir: dir} do
    # Four pictures of 4 MB each: the 15 MB bound fits three of them.
    body = @png <> :binary.copy("x", 4 * 1024 * 1024)
    for name <- ~w(a.png b.png c.png d.png), do: write(dir, name, body)

    history = [
      looked_at("c1", "a.png"),
      looked_at("c2", "b.png"),
      looked_at("c3", "c.png"),
      looked_at("c4", "d.png")
    ]

    [old, newer, newest, too_new] = Images.attach(history, dir, true)

    # The last two were taken — 8 MB of the 15 — the one before them had the room
    # left, and the oldest was over it.
    assert Enum.count(newest.content, &(&1.type == :image)) == 1
    assert Enum.count(too_new.content, &(&1.type == :image)) == 1
    assert Enum.count(newer.content, &(&1.type == :image)) == 1
    refute Enum.any?(old.content, &(&1.type == :image))
  end

  # VISION-12: what a result recorded, and nothing for one that looked at nothing.
  test "looked_at reads the picture a result recorded" do
    assert Images.looked_at(looked_at("c1", "shot.png").content |> List.first()) ==
             %{path: "shot.png", media_type: "image/png", size: 16}

    assert Images.looked_at(Message.tool_result("c1", "ran it")) == nil
    assert Images.looked_at(%{type: :text, text: "hello"}) == nil
    assert Images.looked_at(%{type: :tool_result, image: %{media_type: "image/png"}}) == nil
  end

  # VISION-12, VISION-14: a tool result, as the loop saves and the request reads
  # back: the call, then the result recording the path the look read.
  defp looked_at(id, path) do
    size = if path, do: 16, else: 0

    %Message{
      role: :tool,
      content: [
        Message.tool_result(id, "Looked at #{path}.", false, %{
          image: %{path: path, media_type: Images.media_type(path || ""), size: size}
        })
      ]
    }
  end

  defp call(id, path), do: %Message{role: :assistant, content: [call_block(id, path)]}

  defp call_block(id, path),
    do: %{type: :tool_call, id: id, name: "view_image", input: %{"path" => path}}
end
