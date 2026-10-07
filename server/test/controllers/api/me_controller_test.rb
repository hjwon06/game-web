require "test_helper"

class MeControllerTest < ActionDispatch::IntegrationTest
  test "로그인 전에는 401 이고 후에는 이름을 준다" do
    get "/api/me"
    assert_response :unauthorized

    sign_in_as create_user(name: "제이")
    get "/api/me"
    assert_response :ok
    assert_equal "제이", response.parsed_body["name"]
  end
end
