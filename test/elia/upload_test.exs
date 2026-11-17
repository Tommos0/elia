defmodule Elia.UploadsTest do
  use ExUnit.Case, async: true

  alias Elia.LLM.{Message, OpenAI}
  alias Elia.Uploads

  # UPLOAD-6 to UPLOAD-11: a file the user attaches is written into the chat's
  # own workspace under a name derived from the one the browser gave it, without
  # overwriting what is there, and the message it was attached to names it.

  setup do
    root =
      Path.join(System.tmp_dir!(), "elia-uploads-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  describe "where an attachment lands (UPLOAD-6)" do
    test "it is written into uploads/ under the workspace it is given", %{root: root} do
      refute File.dir?(Path.join(root, "uploads"))

      assert {:ok, "uploads/report.txt"} = Uploads.write(root, "report.txt", "hello")
      assert File.read!(Path.join([root, "uploads", "report.txt"])) == "hello"
    end

    # UPLOAD-6: the chat's own workspace is the one it works in (PROJ-12) — the
    # folder of its project, which for a chat in Elia's own project is the live
    # tree (DEPLOY-1) — so an attachment is where the agent's own tools (FILE)
    # and the Files page look for it (FLINK-5). The view hands this module exactly
    # the root its project's folder resolves to for it (PROJ-12); the
    # LiveView test covers that side of it
    # (`test/elia_web/live/chat_upload_test.exs`).
    test "the directory is created under the root it is given, whatever that is", %{root: root} do
      nested = Path.join(root, "elsewhere")

      assert {:ok, "uploads/a.txt"} = Uploads.write(nested, "a.txt", "x")
      assert File.read!(Path.join([nested, "uploads", "a.txt"])) == "x"
    end
  end

  describe "the name a file keeps (UPLOAD-7)" do
    test "it is the base name of what the browser gave it", %{root: root} do
      assert {:ok, "uploads/shot.png"} = Uploads.write(root, "/etc/shot.png", "x")
      assert {:ok, "uploads/notes.txt"} = Uploads.write(root, "../../notes.txt", "y")
      assert {:ok, "uploads/plain.png"} = Uploads.write(root, "plain.png", "z")
    end

    test "a separator or a control character in it becomes an underscore", %{root: root} do
      assert {:ok, "uploads/a_b.png"} = Uploads.write(root, "a\\b.png", "x")
      assert {:ok, "uploads/c_d.png"} = Uploads.write(root, "c\nd.png", "y")
    end

    test "a name that names no file at all becomes file", %{root: root} do
      assert {:ok, "uploads/file"} = Uploads.write(root, "", "x")
      assert {:ok, "uploads/file-1"} = Uploads.write(root, "..", "y")
      assert {:ok, "uploads/file-2"} = Uploads.write(root, ".", "z")
    end
  end

  describe "a name that is taken (UPLOAD-8)" do
    test "takes the first free number before its extension", %{root: root} do
      assert {:ok, "uploads/shot.png"} = Uploads.write(root, "shot.png", "one")
      assert {:ok, "uploads/shot-1.png"} = Uploads.write(root, "shot.png", "two")
      assert {:ok, "uploads/shot-2.png"} = Uploads.write(root, "shot.png", "three")

      # Each keeps its own contents: nothing was overwritten.
      assert File.read!(Path.join([root, "uploads", "shot.png"])) == "one"
      assert File.read!(Path.join([root, "uploads", "shot-1.png"])) == "two"
      assert File.read!(Path.join([root, "uploads", "shot-2.png"])) == "three"
    end

    test "a name with no extension is numbered the same way", %{root: root} do
      assert {:ok, "uploads/notes"} = Uploads.write(root, "notes", "a")
      assert {:ok, "uploads/notes-1"} = Uploads.write(root, "notes", "b")
    end

    # UPLOAD-8: a file already in uploads/ under that name is not the one the
    # user just attached — an upload joins it rather than replacing it.
    test "a file already there is not overwritten", %{root: root} do
      File.mkdir_p!(Path.join(root, "uploads"))
      File.write!(Path.join([root, "uploads", "mine.txt"]), "not mine")

      assert {:ok, "uploads/mine-1.txt"} = Uploads.write(root, "mine.txt", "mine")
      assert File.read!(Path.join([root, "uploads", "mine.txt"])) == "not mine"
    end
  end

  describe "a file that cannot be written (UPLOAD-9)" do
    test "is an error rather than a silent drop", %{root: root} do
      # A root whose parent is a file: uploads/ cannot be created under it.
      file = Path.join(root, "not-a-directory")
      File.write!(file, "x")

      assert {:error, reason} = Uploads.write(file, "a.txt", "x")
      assert is_atom(reason)
    end
  end

  describe "the message a file is attached to (UPLOAD-10, UPLOAD-11)" do
    test "names the paths in one line after the user's text, in the order attached" do
      message = Message.user("look at these", ["uploads/shot.png", "uploads/report.pdf"])

      assert Message.text_content(message) ==
               "look at these\n\n[Uploaded files: uploads/shot.png, uploads/report.pdf]"

      # UPLOAD-12: what the user wrote is their text, without the harness's line.
      assert Message.user_text(message) == "look at these"
    end

    test "a message that carries only files is the line alone" do
      message = Message.user("", ["uploads/shot.png"])

      assert Message.text_content(message) == "[Uploaded files: uploads/shot.png]"
      assert Message.user_text(message) == ""
    end

    test "a message with no files is what it always was" do
      message = Message.user("hi")

      assert Message.text_content(message) == "hi"
      assert Message.user_text(message) == "hi"
      assert Message.attachments(message) == []
      assert message.meta == %{}
    end

    # UPLOAD-11: the paths are recorded in `meta`, which a provider is never
    # sent (LLM-5) — the line of UPLOAD-10 is what the model reads.
    test "records the paths in its meta, which no provider is sent" do
      message = Message.user("x", ["uploads/a.txt"])

      assert Message.attachments(message) == ["uploads/a.txt"]

      assert [%{"role" => "user", "content" => content}] = OpenAI.encode_messages([message])
      assert content == "x\n\n[Uploaded files: uploads/a.txt]"
    end

    # UPLOAD-11: a message with no files has nothing to record, so a chat saved
    # before this feature and one saved after it carry the same shape.
    test "a message with no files records nothing" do
      assert Message.attachments(Message.user("hi")) == []
      assert Message.attachments(nil) == []
    end
  end

  describe "the title a chat with uploads gets (UPLOAD-14)" do
    # UPLOAD-14, STORE-7: a message whose files are all it carries names nothing,
    # so the title is the first message the user wrote.
    test "a files-only first message leaves the chat unnamed" do
      files_only = [Message.user("", ["uploads/report.txt"])]

      assert Elia.Store.title(files_only) == "New chat"

      assert Elia.Store.title(files_only ++ [Message.user("what do you make of this?")]) ==
               "what do you make of this?"

      # A first message that carries files *and* text is named after its text.
      assert Elia.Store.title([Message.user("have a look", ["uploads/report.txt"])]) ==
               "have a look"
    end
  end
end
