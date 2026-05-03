defmodule SheafWeb.Router do
  @moduledoc """
  Phoenix route table for the reader UI, JSON API, schema, and health endpoints.
  """

  use SheafWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {SheafWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :dashboard do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {SheafWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :dashboard_basic_auth
  end

  scope "/", SheafWeb do
    get "/sheaf-schema.ttl", SchemaController, :show
    get "/health", HealthController, :show
  end

  scope "/api", SheafWeb.API do
    pipe_through :api

    get "/documents", DocumentController, :index
    get "/documents/:id", DocumentController, :show
    get "/documents/:id/chunks", DocumentController, :chunks
    get "/documents/:id/blocks/:block_id", DocumentController, :block
  end

  scope "/rdf", SheafRDFBrowserWeb do
    pipe_through :browser

    live "/", BrowserLive
    live "/ontologies", OntologiesLive
  end

  scope "/", SheafWeb do
    pipe_through :browser

    get "/b/:block_id", BlockController, :show
    live "/", DocumentIndexLive
    live "/search", SearchLive
    live "/history", AssistantHistoryLive
    live "/:id", ResourceLive
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:sheaf, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :dashboard

      live_dashboard "/dashboard", metrics: SheafWeb.Telemetry
    end
  end

  defp dashboard_basic_auth(conn, _opts) do
    username = System.get_env("SHEAF_DASHBOARD_USERNAME", "admin")
    password = System.get_env("SHEAF_DASHBOARD_PASSWORD", "sheaf")

    Plug.BasicAuth.basic_auth(conn, username: username, password: password)
  end
end
