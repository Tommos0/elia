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
  test "an attachment is an image by its extension, whatever the case" do
    assert Images.media_type("uploads/shot.png") == "image/png"
    assert Images.media_type("a.JPG") == "image/jpeg"
    assert Images.media_type("a.jpeg") == "image/jpeg"
    assert Images.media_type("a.WebP") == "image/webp"
    assert Images.media_type("a.gif") == "image/gif"
    assert Images.media_type("notes.txt") == nil
    assert Images.media_type("photo.heic") == nil
    assert Images.media_type("no-extension") == nil

    assert Images.attachment?("uploads/shot.PNG")
    refute Images.attachment?("uploads/notes.md")
  end

  # VISION-2, VISION-3: an image is read from the chat's workspace as the request
  # is built, and the block carries the file's own bytes and its media type.
  test "load reads an image from the workspace", %{dir: dir} do
    write(dir, "shot.png", @png)

    assert {:ok, block} = Images.load(dir, "shot.png")

    assert %{type: :image, media_type: "image/png", path: "shot.png"} = block
    assert Base.decode64!(block.data) == @png

    # The bytes are the file's own; nothing was written or converted.
    assert File.read!(Path.join(dir, "shot.png")) == @png
  end

  # VISION-2: the bytes must be the format the extension names, since the media
  # type sent to a provider would be wrong for them.
  test "a file whose bytes aren't the format its extension names is not an image", %{dir: dir} do
    write(dir, "fake.png", "just text")
    write(dir, "notes.png", "")
    write(dir, "shot.jpg", @png)

    assert Images.load(dir, "fake.png") == :skip
    assert Images.load(dir, "notes.png") == :skip
    assert Images.load(dir, "shot.jpg") == :skip

    # A JPEG that is one, and a WebP whose RIFF body is a WAV, both by signature.
    write(dir, "real.jpg", @jpeg)
    assert {:ok, %{media_type: "image/jpeg"}} = Images.load(dir, "real.jpg")

    write(dir, "sound.webp", "RIFF" <> <<0, 0, 0, 0>> <> "WAVE" <> "data")
    assert Images.load(dir, "sound.webp") == :skip
  end

  test "the other formats' signatures are recognised", %{dir: dir} do
    assert {:ok, %{media_type: "image/gif"}} = Images.load(dir, write(dir, "a.gif", @gif))
    assert {:ok, %{media_type: "image/webp"}} = Images.load(dir, write(dir, "a.webp", @webp))
  end

  # VISION-5: what can't be read is left out rather than failing the turn — a
  # file that isn't there, one that isn't a regular file, a path that leaves the
  # workspace, and a path that leaves it through a symlink.
  test "an attachment that can't be read is skipped", %{dir: dir} do
    outside =
      Path.join(System.tmp_dir!(), "elia-images-out-#{System.unique_integer([:positive])}")

    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "secret.png"), @png)
    on_exit(fn -> File.rm_rf!(outside) end)

    File.mkdir_p!(Path.join(dir, "adir"))

    assert Images.load(dir, "missing.png") == :skip
    assert Images.load(dir, "adir") == :skip
    assert Images.load(dir, "../#{Path.basename(outside)}/secret.png") == :skip
    assert Images.load(dir, Path.join(outside, "secret.png")) == :skip

    File.ln_s!(Path.join(outside, "secret.png"), Path.join(dir, "link.png"))
    assert Images.load(dir, "link.png") == :skip
  end

  # VISION-6: one image is bounded, and so is what a request carries altogether.
  test "an image over a bound is not sent", %{dir: dir} do
    big = @png <> :binary.copy("x", 5 * 1024 * 1024)
    write(dir, "big.png", big)

    assert byte_size(big) > 5 * 1024 * 1024
    assert Images.load(dir, "big.png") == {:error, :too_large}

    # The room a request has left bounds it too.
    assert Images.load(dir, "big.png", 5 * 1024 * 1024) == {:error, :too_large}
    assert Images.load(dir, "big.png", 10) == {:error, :too_large}
  end

  # VISION-1, VISION-4: the images a message carries become blocks of that
  # message, after the blocks it already has, and a model that accepts none is
  # sent the messages as they are.
  test "attach puts the images after the text, in the order they were attached", %{dir: dir} do
    write(dir, "one.png", @png)
    write(dir, "two.jpg", @jpeg)

    message = Message.user("look", ["one.png", "two.jpg"])
    [attached] = Images.attach([message], dir, true)

    assert [%{type: :text}, %{type: :text}, one, two] = attached.content
    assert %{type: :image, media_type: "image/png"} = one
    assert %{type: :image, media_type: "image/jpeg"} = two
    assert Base.decode64!(one.data) == @png

    # The message that was handed in is untouched: nothing image-shaped is
    # stored with the chat (VISION-3).
    assert Enum.map(message.content, & &1.type) == [:text, :text]
    assert Message.text_content(message) =~ "[Uploaded files: one.png, two.jpg]"
    refute Enum.any?(message.content, &(&1.type == :image))

    # VISION-4: no vision, no images — the message is what it is today.
    assert Images.attach([message], dir, false) == [message]

    # And a message carrying no image attachment is unchanged.
    notes = Message.user("read", ["notes.txt"])
    assert Images.attach([notes], dir, true) == [notes]
  end

  # VISION-6: the images one request carries are bounded from the newest message
  # first, so what the user just sent is sent before a picture from earlier.
  test "the newest message's images are taken first", %{dir: dir} do
    # Four images of 4 MB each: the 15 MB bound fits three of them.
    body = @png <> :binary.copy("x", 4 * 1024 * 1024)
    for name <- ~w(a.png b.png c.png d.png), do: write(dir, name, body)

    old = Message.user("old", ["a.png"])
    newer = Message.user("newer", ["b.png"])
    newest = Message.user("newest", ["c.png", "d.png"])

    [old, newer, newest] = Images.attach([old, newer, newest], dir, true)

    # The newest message's two images were taken, the message before it kept one
    # of its own, and the oldest message's image was over the room left.
    assert Enum.count(newest.content, &(&1.type == :image)) == 2
    assert Enum.count(newer.content, &(&1.type == :image)) == 1
    refute Enum.any?(old.content, &(&1.type == :image))

    # An image that was left out keeps its message's own path line (VISION-5).
    assert Enum.any?(old.content, &(&1[:note] == :uploads))
  end
end
