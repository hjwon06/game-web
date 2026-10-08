require "test_helper"

class CampusPageTest < ActionDispatch::IntegrationTest
  CAMPUS_HTML = Rails.root.join("..", "campus.html").expand_path

  test "비로그인 /campus 는 /login 으로 보낸다(계정 0행이면 /setup)" do
    get "/campus"
    assert_redirected_to "/setup"
    create_user
    get "/campus"
    assert_redirected_to "/login"
  end

  test "로그인 후 /campus 는 base 태그만 더한 campus.html 을 준다" do
    skip "campus.html 이 아직 없다(C2 셀 산출물)" unless CAMPUS_HTML.exist?
    sign_in_as create_user
    get "/campus"
    assert_response :ok
    assert_equal "text/html", response.media_type
    assert_match(%r{<head[^>]*>\s*<base href="/v/\d+/">}, response.body)
    stripped = response.body.b.sub(%r{\n  <base href="/v/\d+/">}n, "")
    assert_equal File.binread(CAMPUS_HTML), stripped
  end

  test "버전 계산 대상에 campus.html 과 src/campus/*.js 가 들어 있다" do
    assert_includes HomeController::VERSIONED, "campus.html"
    assert_includes HomeController::VERSIONED, "src/campus/*.js"
  end

  test "/ 는 여전히 index.html 을 준다" do
    sign_in_as create_user
    get "/"
    assert_response :ok
    stripped = response.body.b.sub(%r{\n  <base href="/v/\d+/">}n, "")
    assert_equal File.binread(Rails.root.join("..", "index.html")), stripped
  end
end
