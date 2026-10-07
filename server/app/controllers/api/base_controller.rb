# ApplicationController 를 상속하지 않는다. allow_browser·importmap etag 는 JSON API 에 맞지 않는다.
# 인증은 로그인 세션 쿠키다. 없으면 401 JSON.
module Api
  class BaseController < ActionController::Base
    include Authentication

    # CSRF 토큰 검사는 끈다. 대신 세션 쿠키가 SameSite=Lax 라서 다른 사이트에서 오는
    # POST 요청에는 브라우저가 쿠키를 싣지 않는다 -> 교차 사이트 POST 는 401 로 막힌다.
    skip_forgery_protection

    private
      def request_authentication
        render json: { error: "login_required" }, status: :unauthorized
      end
  end
end
