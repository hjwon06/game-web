require "test_helper"

class Campus3dPageTest < ActionDispatch::IntegrationTest
  CAMPUS3D_HTML = Rails.root.join("..", "campus3d.html").expand_path

  test "비로그인 /campus3d 는 /login 으로 보낸다(계정 0행이면 /setup)" do
    get "/campus3d"
    assert_redirected_to "/setup"
    create_user
    get "/campus3d"
    assert_redirected_to "/login"
  end

  test "로그인 후 /campus3d 는 base 태그만 더한 campus3d.html 을 준다" do
    skip "campus3d.html 이 아직 없다(3D-① 셀 산출물)" unless CAMPUS3D_HTML.exist?
    sign_in_as create_user
    get "/campus3d"
    assert_response :ok
    assert_equal "text/html", response.media_type
    assert_match(%r{<head[^>]*>\s*<base href="/v/\d+/">}, response.body)
    stripped = response.body.b.sub(%r{\n  <base href="/v/\d+/">}n, "")
    assert_equal File.binread(CAMPUS3D_HTML), stripped
  end

  test "버전 계산 대상에 campus3d.html 과 src/c3d/*.js 가 들어 있다" do
    assert_includes HomeController::VERSIONED, "campus3d.html"
    assert_includes HomeController::VERSIONED, "src/c3d/*.js"
  end
end
