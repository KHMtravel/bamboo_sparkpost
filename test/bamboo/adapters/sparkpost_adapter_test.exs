defmodule Bamboo.SparkPostAdapterTest do
  use ExUnit.Case
  alias Bamboo.Email
  alias Bamboo.SparkPostAdapter
  alias Bamboo.SparkPostHelper
  alias Bamboo.Attachment

  @config %{adapter: SparkPostAdapter, api_key: "123_abc"}
  @config_with_bad_key %{adapter: SparkPostAdapter, api_key: nil}

  defmodule FakeSparkPost do
    use Plug.Router

    plug(
      Plug.Parsers,
      parsers: [:urlencoded, :multipart, :json],
      pass: ["*/*"],
      json_decoder: Bamboo.SparkPostAdapter.json_library()
    )

    plug(:match)
    plug(:dispatch)

    def start_server(parent) do
      Agent.start_link(fn -> Map.new() end, name: __MODULE__)
      Agent.update(__MODULE__, &Map.put(&1, :parent, parent))
      port = get_free_port()

      Application.put_env(:bamboo, :sparkpost_base_uri, "http://localhost:#{port}/")
      Plug.Adapters.Cowboy.http(__MODULE__, [], port: port, ref: __MODULE__)
    end

    def get_free_port do
      {:ok, socket} = :ranch_tcp.listen(port: 0)
      {:ok, port} = :inet.port(socket)
      :erlang.port_close(socket)
      port
    end

    def shutdown do
      Plug.Adapters.Cowboy.shutdown(__MODULE__)
    end

    post "/api/v1/transmissions" do
      case get_in(conn.params, ["content", "from", "email"]) do
        "INVALID_EMAIL" -> conn |> send_resp(500, "Error!!") |> send_to_parent
        _ -> conn |> send_resp(200, "SENT") |> send_to_parent
      end
    end

    defp send_to_parent(conn) do
      parent = Agent.get(__MODULE__, fn set -> Map.get(set, :parent) end)
      send(parent, {:fake_sparkpost, conn})
      conn
    end
  end

  setup do
    FakeSparkPost.start_server(self())

    on_exit(fn ->
      FakeSparkPost.shutdown()
    end)

    :ok
  end

  test "raises if the api key is nil" do
    assert_raise ArgumentError, ~r/no API key set/, fn ->
      new_email(from: "foo@bar.com") |> SparkPostAdapter.deliver(@config_with_bad_key)
    end

    assert_raise ArgumentError, ~r/no API key set/, fn ->
      SparkPostAdapter.handle_config(%{})
    end
  end

  test "deliver/2 sends the to the right url" do
    new_email() |> SparkPostAdapter.deliver(@config)

    assert_receive {:fake_sparkpost, %{request_path: request_path}}

    assert request_path == "/api/v1/transmissions"
  end

  test "deliver/2 sends from, html and text body, subject, reply_to, headers, and attachments" do
    email =
      new_email(
        from: {"From", "from@foo.com"},
        subject: "My Subject",
        text_body: "TEXT BODY",
        html_body: "HTML BODY"
      )
      |> Email.put_header("Reply-To", "reply@foo.com")
      |> Email.put_attachment(Path.join(__DIR__, "../../support/attachment.txt"))

    email |> SparkPostAdapter.deliver(@config)

    assert_receive {:fake_sparkpost, %{params: params} = conn}
    assert Plug.Conn.get_req_header(conn, "content-type") == ["application/json"]
    assert Plug.Conn.get_req_header(conn, "authorization") == [@config[:api_key]]

    message = params["content"]
    assert message["from"]["name"] == email.from |> elem(0)
    assert message["from"]["email"] == email.from |> elem(1)
    assert message["subject"] == email.subject
    assert message["text"] == email.text_body
    assert message["html"] == email.html_body
    assert message["headers"] == %{}
    assert message["reply_to"] == "reply@foo.com"

    assert message["attachments"] == [
             %{
               "type" => "text/plain",
               "name" => "attachment.txt",
               "data" => "VGVzdCBBdHRhY2htZW50Cg=="
             }
           ]
  end

  test "deliver/2 handles binary attachments" do
    email =
      new_email(
        from: {"From", "from@foo.com"},
        subject: "My Subject",
        text_body: "TEXT BODY",
        html_body: "HTML BODY"
      )
      |> Email.put_attachment(%Attachment{
        data: File.read!(Path.join(__DIR__, "../../support/attachment.txt")),
        filename: "test.txt",
        content_type: "text/plain"
      })

    email |> SparkPostAdapter.deliver(@config)

    assert_receive {:fake_sparkpost, %{params: params}}

    message = params["content"]

    assert message["attachments"] == [
             %{
               "type" => "text/plain",
               "name" => "test.txt",
               "data" => "VGVzdCBBdHRhY2htZW50Cg=="
             }
           ]
  end

  test "deliver/2 correctly formats recipients" do
    email =
      new_email(
        to: [{"To", "to@bar.com"}],
        cc: [{"CC", "cc@bar.com"}],
        bcc: [{"BCC", "bcc@bar.com"}]
      )

    email |> SparkPostAdapter.deliver(@config)

    assert_receive {:fake_sparkpost,
                    %{params: %{"recipients" => recipients, "content" => %{"headers" => headers}}}}

    assert recipients == [
             %{"address" => %{"name" => "To", "email" => "to@bar.com"}},
             %{
               "address" => %{
                 "name" => "CC",
                 "email" => "cc@bar.com",
                 "header_to" => "to@bar.com"
               }
             },
             %{
               "address" => %{
                 "name" => "BCC",
                 "email" => "bcc@bar.com",
                 "header_to" => "to@bar.com"
               }
             }
           ]

    assert headers["CC"] == "cc@bar.com"
  end

  test "deliver/2 adds extra params to the message " do
    email = new_email() |> SparkPostHelper.mark_transactional()

    email |> SparkPostAdapter.deliver(@config)

    assert_receive {:fake_sparkpost, %{params: params}}, 200
    assert params["options"] == %{"transactional" => true}
  end

  test "deliver/2 adds tags to the recipients" do
    email =
      new_email(to: ["foo@example.com", "bar@example.com"]) |> SparkPostHelper.tag("test-tag")

    email |> SparkPostAdapter.deliver(@config)

    assert_receive {:fake_sparkpost, %{params: params}}

    assert params["recipients"] == [
             %{
               "address" => %{"email" => "foo@example.com", "name" => nil},
               "tags" => ["test-tag"]
             },
             %{
               "address" => %{"email" => "bar@example.com", "name" => nil},
               "tags" => ["test-tag"]
             }
           ]
  end

  test "deliver/2 adds request headers specified in the config" do
    config = %{
      adapter: SparkPostAdapter,
      api_key: "123_abc",
      request_headers: [{"X-MSYS-SUBACCOUNT", "123"}]
    }

    new_email() |> SparkPostAdapter.deliver(config)

    assert_receive {:fake_sparkpost, %{params: _params} = conn}
    assert Plug.Conn.get_req_header(conn, "content-type") == ["application/json"]
    assert Plug.Conn.get_req_header(conn, "authorization") == [config[:api_key]]
    assert Plug.Conn.get_req_header(conn, "x-msys-subaccount") == ["123"]
  end

  describe "error responses" do
    setup do
      email =
        new_email(
          from: "INVALID_EMAIL",
          subject: "My Subject",
          text_body: "TEXT BODY",
          html_body:
            "<!DOCTYPE html><html xmlns=\"http://www.w3.org/1999/xhtml\">\n<head><title>Email</title>\n<style type=\"text/css\">\nbody {\n width: 100% !important; }\n\n</style>\n</head><body><p>\n<a href=\"https://www.example.org?utm_medium=email&utm_source=campaign\">Contact us</a>\n</p></body></html>"
        )

      {:ok, email: email}
    end

    test "raises if the response is not a success", %{email: email} do
      assert_raise Bamboo.ApiError, fn ->
        email |> SparkPostAdapter.deliver(@config)
      end
    end

    test "removes api key from error output", %{email: email} do
      assert_raise Bamboo.ApiError, ~r/"key" => "\[FILTERED\]"/, fn ->
        email |> SparkPostAdapter.deliver(@config)
      end
    end
  end

  defp new_email(attrs \\ []) do
    attrs = Keyword.merge([from: "foo@bar.com", to: []], attrs)
    Email.new_email(attrs) |> Bamboo.Mailer.normalize_addresses()
  end
end
