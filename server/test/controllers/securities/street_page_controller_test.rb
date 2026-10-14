require "test_helper"
require "tmpdir"

# /sec3d. 화면 파일은 임시 디렉터리의 것으로 바꿔 끼운다(레포 루트의 sec3d.html 에 기대지 않는다).
class StreetPageControllerTest < ActionDispatch::IntegrationTest
  HTML = %(<!doctype html>\n<html lang="ko">\n<head>\n  <title>거리</title>\n</head>\n<body><canvas id="s3d"></canvas></body>\n</html>\n).freeze

  setup do
    @dir = Dir.mktmpdir("sec_page")
    @page = Pathname(@dir).join("sec3d.html")
    @page.write(HTML)
    @saved_page = Securities::StreetPageController.page
    Securities::StreetPageController.page = @page
  end

  teardown do
    Securities::StreetPageController.page = @saved_page
    FileUtils.remove_entry(@dir)
  end

  test "T1 비로그인은 로그인으로 보낸다(본문을 내리지 않는다)" do
    create_user
    get "/sec3d"

    assert_redirected_to "/login"
    assert_not_includes response.body, "s3d"
  end

  test "T1 로그인하면 200 이고 base 가 /v/{VER}/ 로 head 안에 들어간다" do
    sign_in_as create_user
    get "/sec3d"

    assert_response :ok
    assert_match %r{<head>\n  <base href="/v/\d+/">}, response.body
    assert_includes response.body, %(<canvas id="s3d">)
  end

  test "화면 파일이 없으면 500 이 아니라 404 다" do
    sign_in_as create_user
    @page.delete
    get "/sec3d"

    assert_response :not_found
  end

  test "버전 목록은 sec3d.html · src/s3d · src/c3d 다" do
    assert_equal ["sec3d.html", "src/s3d/*.js", "src/c3d/*.js"], Securities::StreetPageController::VERSIONED
  end
end
