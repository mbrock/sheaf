defmodule Sheaf.XLSXFixture do
  @moduledoc false

  def write_xlsx!(path, rows) do
    write_workbook!(path, [{"Sheet1", rows}])
  end

  def write_workbook!(path, sheets) do
    entries =
      [
        {~c"[Content_Types].xml", content_types(sheets)},
        {~c"_rels/.rels", package_rels()},
        {~c"xl/workbook.xml", workbook(sheets)},
        {~c"xl/_rels/workbook.xml.rels", workbook_rels(sheets)}
      ] ++ worksheet_entries(sheets)

    {:ok, _path} = :zip.create(String.to_charlist(path), entries)
    path
  end

  defp content_types(sheets) do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
      <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
      <Default Extension="xml" ContentType="application/xml"/>
      <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
      #{Enum.with_index(sheets, 1) |> Enum.map_join("\n", fn {_sheet, index} -> worksheet_content_type(index) end)}
    </Types>
    """
  end

  defp worksheet_content_type(index) do
    ~s(<Override PartName="/xl/worksheets/sheet#{index}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>)
  end

  defp package_rels do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
    </Relationships>
    """
  end

  defp workbook(sheets) do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"
      xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
      <sheets>
        #{Enum.with_index(sheets, 1) |> Enum.map_join("\n", fn {{name, _rows}, index} -> sheet_xml(name, index) end)}
      </sheets>
    </workbook>
    """
  end

  defp sheet_xml(name, index) do
    ~s(<sheet name="#{escape_xml(name)}" sheetId="#{index}" r:id="rId#{index}"/>)
  end

  defp workbook_rels(sheets) do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      #{Enum.with_index(sheets, 1) |> Enum.map_join("\n", fn {_sheet, index} -> worksheet_rel(index) end)}
    </Relationships>
    """
  end

  defp worksheet_rel(index) do
    ~s(<Relationship Id="rId#{index}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet#{index}.xml"/>)
  end

  defp worksheet_entries(sheets) do
    sheets
    |> Enum.with_index(1)
    |> Enum.map(fn {{_name, rows}, index} ->
      {String.to_charlist("xl/worksheets/sheet#{index}.xml"), worksheet(rows)}
    end)
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
    |> String.replace("\"", "&quot;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
