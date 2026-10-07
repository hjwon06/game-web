require "test_helper"

class ApiTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as create_user
    Machine.create!(code: "M2", name: "조립기", state: "stopped")
    Machine.create!(code: "M1", name: "절단기", state: "running")
  end

  def post_command(kind, base_version, key: SecureRandom.uuid, code: "M1")
    post "/api/commands", params: { idempotency_key: key, machine_code: code, kind: kind,
                                    base_version: base_version }, as: :json
  end

  test "GET /api/state 는 code 순서로 내려주고 같은 ETag 면 304 다" do
    get "/api/state"
    assert_response :ok
    body = response.parsed_body
    assert_equal %w[M1 M2], body["machines"].map { |m| m["code"] }
    assert_equal 0, body["version"]

    etag = response.headers["ETag"]
    assert etag.present?
    get "/api/state", headers: { "If-None-Match" => etag }
    assert_response :not_modified
  end

  test "명령 후에는 ETag 가 바뀌어 200 으로 새 상태를 준다" do
    get "/api/state"
    old_etag = response.headers["ETag"]

    post_command("stop", 0)
    assert_response :ok

    get "/api/state", headers: { "If-None-Match" => old_etag }
    assert_response :ok
    assert_equal 1, response.parsed_body["version"]
  end

  test "POST 정상 후 GET 에서 바뀐 state 가 유지된다" do
    post_command("stop", 0)
    assert_response :ok
    assert_equal({ "code" => "M1", "state" => "stopped", "version" => 1 }, response.parsed_body["machine"])

    get "/api/state"
    m1 = response.parsed_body["machines"].find { |m| m["code"] == "M1" }
    assert_equal ["stopped", 1], [m1["state"], m1["version"]]
  end

  test "같은 키 재전송은 같은 응답이고 낡은 base_version 은 409 다" do
    key = SecureRandom.uuid
    post_command("stop", 0, key: key)
    first = response.parsed_body
    post_command("stop", 0, key: key)
    assert_response :ok
    assert_equal first, response.parsed_body

    post_command("start", 0)
    assert_response :conflict
    assert_equal 409, response.parsed_body["result_status"]
  end

  test "없는 기계는 404, 불가 전이는 422 다" do
    post_command("start", 0, code: "M9")
    assert_response :not_found
    assert_nil response.parsed_body["machine"]

    post_command("repair", 0)
    assert_response :unprocessable_entity
  end
end
