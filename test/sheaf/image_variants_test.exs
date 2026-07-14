defmodule Sheaf.ImageVariantsTest do
  use ExUnit.Case, async: true

  alias Sheaf.ImageVariants

  @moduletag :tmp_dir

  test "builds a WebP cover once and reuses the cached derivative", %{
    tmp_dir: tmp_dir
  } do
    source = Path.join(tmp_dir, "source.png")
    File.write!(source, "large png")
    test_pid = self()

    convert = fn ^source, destination ->
      send(test_pid, {:convert, destination})
      File.write(destination, "small webp")
    end

    image = %{
      image_id: "IMG123",
      path: source,
      sha256: String.duplicate("a", 64)
    }

    assert {:ok, first} = ImageVariants.cover(image, convert: convert)
    assert first.mime_type == "image/webp"
    assert first.byte_size == byte_size("small webp")

    assert first.etag ==
             ~s("sha256-#{String.duplicate("a", 64)}-cover-v1")

    assert_received {:convert, temporary}
    refute File.exists?(temporary)
    assert File.read!(first.path) == "small webp"

    assert {:ok, second} = ImageVariants.cover(image, convert: convert)
    assert second == first
    refute_received {:convert, _temporary}
  end
end
