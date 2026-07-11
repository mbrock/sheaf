defmodule Sheaf.SafeFetchTest do
  use ExUnit.Case, async: true

  test "rejects non-HTTPS and private-network targets before requesting" do
    assert {:error, :https_required} =
             Sheaf.SafeFetch.download_pdf("http://example.com/paper.pdf")

    assert {:error, :private_network_not_allowed} =
             Sheaf.SafeFetch.download_pdf("https://127.0.0.1/paper.pdf")

    assert {:error, :userinfo_not_allowed} =
             Sheaf.SafeFetch.download_pdf(
               "https://user@example.com/paper.pdf"
             )
  end
end
