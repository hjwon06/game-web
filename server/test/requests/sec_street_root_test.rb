require "test_helper"

class SecStreetRootTest < ActionDispatch::IntegrationTest
  def with_street(value)
    before = ENV["SEC_STREET"]
    value.nil? ? ENV.delete("SEC_STREET") : ENV["SEC_STREET"] = value
    yield
  ensure
    before.nil? ? ENV.delete("SEC_STREET") : ENV["SEC_STREET"] = before
  end

  test "SEC_STREET 켬: GET / 는 /sec3d 로 302" do
    with_street("1") do
      get "/"
      assert_response :found
      assert_redirected_to "/sec3d"
      create_user
      get "/"
      assert_redirected_to "/sec3d"
    end
  end

  test "SEC_STREET 켬: 로그인 화면은 증권 거리 문구이고 1공장이 없다" do
    with_street("1") do
      create_user
      get "/login"
      assert_response :ok
      assert_includes response.body, "증권 거리"
      assert_not_includes response.body, "1공장"
    end
  end

  test "SEC_STREET 끔: GET / 는 지금처럼 home#show(비로그인이면 로그인으로)" do
    with_street(nil) do
      create_user
      get "/"
      assert_redirected_to "/login"
    end
  end

  test "SEC_STREET 끔: 로그인 화면은 1공장 그대로" do
    with_street(nil) do
      create_user
      get "/login"
      assert_response :ok
      assert_includes response.body, "1공장"
      assert_not_includes response.body, "증권 거리"
    end
  end
end
