# Generates the PWA icons (PWA-6). Run from the project root:
#
#     elixir assets/pwa_icons.exs
#
# Draws a white "E" on a dark square. The letter stays inside the central 60%
# of the image so the same files work as maskable icons.

defmodule PwaIcons do
  @bg {17, 24, 39}
  @fg {255, 255, 255}

  # Rectangles of the letter in unit coordinates: {x0, y0, x1, y1}.
  @rects [
    {0.34, 0.28, 0.44, 0.72},
    {0.34, 0.28, 0.66, 0.38},
    {0.34, 0.45, 0.62, 0.55},
    {0.34, 0.62, 0.66, 0.72}
  ]

  def write(path, size) do
    rows =
      for y <- 0..(size - 1) do
        pixels =
          for x <- 0..(size - 1), into: <<>> do
            {r, g, b} = color((x + 0.5) / size, (y + 0.5) / size)
            <<r, g, b>>
          end

        <<0, pixels::binary>>
      end

    ihdr = <<size::32, size::32, 8, 2, 0, 0, 0>>

    png =
      <<137, 80, 78, 71, 13, 10, 26, 10>> <>
        chunk("IHDR", ihdr) <>
        chunk("IDAT", :zlib.compress(IO.iodata_to_binary(rows))) <>
        chunk("IEND", <<>>)

    File.write!(path, png)
  end

  defp color(u, v) do
    if Enum.any?(@rects, fn {x0, y0, x1, y1} -> u >= x0 and u < x1 and v >= y0 and v < y1 end),
      do: @fg,
      else: @bg
  end

  defp chunk(type, data) do
    <<byte_size(data)::32, type::binary, data::binary, :erlang.crc32([type, data])::32>>
  end
end

dir = Path.expand("../priv/static/images", __DIR__)

for {name, size} <- [{"icon-192.png", 192}, {"icon-512.png", 512}, {"apple-touch-icon.png", 180}] do
  PwaIcons.write(Path.join(dir, name), size)
end
