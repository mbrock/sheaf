defmodule Sheaf.XLSXFixture do
  @moduledoc false

  def write_xlsx!(path, rows) do
    entries = [
      {~c"[Content_Types].xml", content_types()},
      {~c"_rels/.rels", package_rels()},
      {~c"xl/workbook.xml", workbook()},
      {~c"xl/_rels/workbook.xml.rels", workbook_rels()},
      {~c"xl/worksheets/sheet1.xml", worksheet(rows)}
    ]

    {:ok, _path} = :zip.create(String.to_charlist(path), entries)
    path
  end

  defp content_types do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
      <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
      <Default Extension="xml" ContentType="application/xml"/>
      <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
      <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
    </Types>
    """
  end

  defp package_rels do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
    </Relationships>
    """
  end

  defp workbook do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"
      xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
      <sheets>
        <sheet name="Sheet1" sheetId="1" r:id="rId1"/>
      </sheets>
    </workbook>
    """
  end

  defp workbook_rels do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
    </Relationships>
    """
  end

  defp worksheet(rows) do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
      <sheetData>
        #{Enum.with_index(rows, 1) |> Enum.map_join("\n", fn {row, index} -> row_xml(row, index) end)}
      </sheetData>
    </worksheet>
    """
  end

  defp row_xml(values, row_index) do
    cells =
      values
      |> Enum.with_index(1)
      |> Enum.map_join(fn {value, col_index} ->
        """
        <c r="#{cell_ref(col_index, row_index)}" t="inlineStr"><is><t>#{escape_xml(value)}</t></is></c>
        """
      end)

    ~s(<row r="#{row_index}">#{cells}</row>)
  end

  defp cell_ref(col_index, row_index), do: column_name(col_index) <> Integer.to_string(row_index)

  defp column_name(index) do
    index
    |> Stream.unfold(fn
      0 ->
        nil

      value ->
        value = value - 1
        {<<rem(value, 26) + ?A>>, div(value, 26)}
    end)
    |> Enum.reverse()
    |> Enum.join()
  end

  defp escape_xml(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
