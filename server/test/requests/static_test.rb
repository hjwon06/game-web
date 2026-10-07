require "test_helper"

class StaticTest < ActionDispatch::IntegrationTest
  ROOT = Rails.root.join("..").expand_path

  test "허용 파일은 로그인 없이 200, no-store, 확장자별 content-type 이다" do
    {
      "styles.css" => "text/css",
      "src/main.js" => "text/javascript",
      "data/factory.json" => "application/json",
      "assets/kenney-tiny-factory/Tiles/tile_0000.png" => "image/png"
    }.each do |path, type|
      get "/v/123/#{path}"
      assert_response :ok, path
      assert_equal "no-store", response.headers["Cache-Control"], path
      assert_equal type, response.media_type, path
      assert_equal File.binread(ROOT.join(path)), response.body.b, path
    end
  end

  test "ver 값은 검사하지 않는다" do
    get "/v/아무거나/styles.css"
    assert_response :ok
  end

  test "상위 경로(..)가 들어가면 404 다" do
    get "/v/1/src/../server/config/routes.rb"
    assert_response :not_found
    get "/v/1/src/%2e%2e/server/config/routes.rb"
    assert_response :not_found
    get "/v/1/..%2Fserver/config/routes.rb"
    assert_response :not_found
    get "/v/1/src/..%2F..%2Fserver%2Fconfig%2Froutes.rb"
    assert_response :not_found
  end

  test "허용 목록 밖은 404 다" do
    get "/v/1/server/config/routes.rb"
    assert_response :not_found
    get "/v/1/index.html"
    assert_response :not_found
    get "/v/1/styles.css.bak"
    assert_response :not_found
    get "/v/1/src/nope.js"
    assert_response :not_found
    get "/v/1//etc/passwd"
    assert_response :not_found
  end

  test "GET / 본문 head 안에 <base href=/v/...> 가 들어가고 나머지는 원문 그대로다" do
    sign_in_as create_user
    get "/"
    assert_response :ok
    assert_match(%r{<head>\s*<base href="/v/\d+/">}, response.body)
    assert_includes response.body, '<base href="/v/'
    original = File.read(ROOT.join("index.html"))
    assert_equal original, response.body.sub(%r{\n  <base href="/v/\d+/">}, "")
  end
end
