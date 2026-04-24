defmodule SheafWeb.BlockController do
  @moduledoc """
  Resolves bare block ids to the containing document and redirects there.

  Powers the `#BLOCKID` links the assistant produces: `/b/NT2AGV` figures out
  which document contains the block and redirects to
  `/42YBLA?block=NT2AGV#block-NT2AGV`.
  """

  use SheafWeb, :controller

  alias Sheaf.Corpus

  def show(conn, %{"block_id" => block_id}) do
    case Corpus.find_document(block_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> text("block #{block_id} not found")

      doc_id when doc_id == block_id ->
        redirect(conn, to: ~p"/#{doc_id}")

      doc_id ->
        redirect(conn, to: "/#{doc_id}?block=#{block_id}#block-#{block_id}")
    end
  end
end
