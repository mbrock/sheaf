defmodule Sheaf.Assistant.ToolResults do
  @moduledoc """
  Typed results returned by assistant corpus tools.

  These structs are the internal shape. `Sheaf.Assistant.ToolResultText`
  owns the model-facing text rendering.
  """

  defmodule ListDocuments do
    defstruct documents: []
  end

  defmodule DocumentSummary do
    defstruct [
      :id,
      :kind,
      :metadata_kind,
      :title,
      :authors,
      :year,
      :page_count,
      :doi,
      :venue,
      :publisher,
      :pages,
      :status,
      cited?: false,
      has_document?: true,
      workspace_owner_authored?: false
    ]
  end

  defmodule Document do
    defstruct [
      :id,
      :title,
      :kind,
      outline: []
    ]
  end

  defmodule OutlineEntry do
    defstruct [
      :id,
      :number,
      :title,
      children: []
    ]
  end

  defmodule Block do
    defstruct [
      :document_id,
      :id,
      :type,
      :title,
      :kind,
      :text,
      :source,
      :coding,
      ancestry: [],
      children: [],
      outline: []
    ]
  end

  defmodule Blocks do
    defstruct [
      :document_id,
      blocks: [],
      expanded?: false
    ]
  end

  defmodule Child do
    defstruct [
      :id,
      :type,
      :title,
      :preview
    ]
  end

  defmodule ContextEntry do
    defstruct [
      :id,
      :type,
      :title
    ]
  end

  defmodule Source do
    defstruct [
      :key,
      :page,
      :type
    ]
  end

  defmodule Coding do
    defstruct [
      :row,
      :source,
      :category,
      :category_title
    ]
  end

  defmodule SearchResults do
    defstruct exact_results: [],
              approximate_results: []
  end

  defmodule ListSpreadsheets do
    defstruct spreadsheets: [],
              query: nil,
              total_spreadsheets: 0,
              total_sheets: 0,
              returned_spreadsheets: 0,
              returned_sheets: 0,
              limit: nil,
              truncated?: false
  end

  defmodule Spreadsheet do
    defstruct [
      :id,
      :title,
      :path,
      sheets: []
    ]
  end

  defmodule SpreadsheetSheet do
    defstruct [
      :spreadsheet_id,
      :name,
      :table_name,
      :row_count,
      :col_count,
      columns: []
    ]
  end

  defmodule SpreadsheetQuery do
    defstruct [
      :intent,
      :sql,
      :result_id,
      :result_iri,
      :result_file_iri,
      row_count: 0,
      offset: 0,
      limit: nil,
      columns: [],
      rows: []
    ]
  end

  defmodule SpreadsheetQueryResultPage do
    defstruct [
      :id,
      :iri,
      :file_iri,
      :sql,
      row_count: 0,
      offset: 0,
      limit: nil,
      columns: [],
      rows: []
    ]
  end

  defmodule SpreadsheetSearch do
    defstruct [
      :query,
      hits: []
    ]
  end

  defmodule SearchHit do
    defstruct [
      :document_id,
      :document_title,
      :document_authors,
      :block_id,
      :kind,
      :text,
      :source_page,
      :match,
      :score,
      :coding,
      context: []
    ]
  end

  defmodule Note do
    defstruct [
      :id,
      :iri
    ]
  end

  defmodule ParagraphTags do
    defstruct block_ids: [],
              tags: [],
              tag_iris: [],
              statement_count: 0
  end
end
