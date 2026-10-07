require "test_helper"

class AuthTest < ActionDispatch::IntegrationTest
  FAIL_TEXT = "이름 또는 비밀번호가 맞지 않습니다".freeze

  test "로그인 성공은 / 로 보내고 이후 /api/me 가 이름을 준다" do
    create_user
    post "/login", params: { name: "jay", password: AuthHelper::TEST_PASSWORD }
    assert_redirected_to "/"
    assert_equal 1, Session.count

    get "/api/me"
    assert_response :ok
    assert_equal({ "name" => "jay" }, response.parsed_body)
  end

  test "이름이 틀려도 비밀번호가 틀려도 같은 문구이고 세션이 안 생긴다" do
    create_user
    post "/login", params: { name: "jay", password: "wrong" }
    assert_response :unprocessable_entity
    assert_includes response.body, FAIL_TEXT
    post "/login", params: { name: "nobody", password: AuthHelper::TEST_PASSWORD }
    assert_response :unprocessable_entity
    assert_includes response.body, FAIL_TEXT
    assert_equal 0, Session.count
    get "/api/state"
    assert_response :unauthorized
  end

  test "로그아웃은 GET 과 DELETE 모두 세션을 지우고 /login 으로 보낸다" do
    user = create_user
    sign_in_as user
    get "/logout"
    assert_redirected_to "/login"
    assert_equal 0, Session.count
    get "/api/state"
    assert_response :unauthorized

    sign_in_as user
    delete "/logout"
    assert_redirected_to "/login"
    assert_equal 0, Session.count
  end

  test "세션 쿠키는 httponly 와 SameSite=Lax 다" do
    create_user
    post "/login", params: { name: "jay", password: AuthHelper::TEST_PASSWORD }
    cookie = response.headers["Set-Cookie"]
    assert_match(/session_id=/, cookie)
    assert_match(/httponly/i, cookie)
    assert_match(/samesite=lax/i, cookie)
  end

  test "/setup 은 계정이 0행일 때만 열리고 만든 뒤 로그인 상태가 된다" do
    get "/setup"
    assert_response :ok
    post "/setup", params: { name: "jay", password: "secret-pass-1", password_confirmation: "mismatch" }
    assert_response :unprocessable_entity
    assert_includes response.body, "비밀번호가 서로 다릅니다"
    assert_equal 0, User.count

    post "/setup", params: { name: "", password: "secret-pass-1", password_confirmation: "secret-pass-1" }
    assert_response :unprocessable_entity
    assert_includes response.body, "이름을 입력해 주세요"
    post "/setup", params: { name: "jay", password: "", password_confirmation: "" }
    assert_response :unprocessable_entity
    assert_includes response.body, "비밀번호를 입력해 주세요"
    assert_equal 0, User.count

    post "/setup", params: { name: "jay", password: "secret-pass-1", password_confirmation: "secret-pass-1" }
    assert_redirected_to "/"
    assert_equal 1, User.count
    get "/api/me"
    assert_response :ok

    get "/setup"
    assert_redirected_to "/login"
    post "/setup", params: { name: "x", password: "secret-pass-2", password_confirmation: "secret-pass-2" }
    assert_redirected_to "/login"
    assert_equal 1, User.count
  end

  test "비로그인: / 는 /login(계정 0행이면 /setup), API 는 401 JSON 이다" do
    get "/"
    assert_redirected_to "/setup"
    create_user
    get "/"
    assert_redirected_to "/login"

    get "/api/state"
    assert_response :unauthorized
    assert_equal({ "error" => "login_required" }, response.parsed_body)
    get "/api/hud"
    assert_response :unauthorized
    get "/api/me"
    assert_response :unauthorized
    post "/api/commands", params: { machine_code: "M1", kind: "stop", base_version: 0,
                                    idempotency_key: SecureRandom.uuid }, as: :json
    assert_response :unauthorized
  end

  test "로그인 후 / 는 base 태그만 더한 공장 화면 index.html 을 준다" do
    sign_in_as create_user
    get "/"
    assert_response :ok
    assert_equal "text/html", response.media_type
    assert_match(%r{<base href="/v/\d+/">}, response.body)
    stripped = response.body.b.sub(%r{\n  <base href="/v/\d+/">}n, "")
    assert_equal File.binread(Rails.root.join("..", "index.html")), stripped
  end
end
