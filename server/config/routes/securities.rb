# 증권 거리 화면(⑦). config/routes.rb 가 draw :securities 로 읽는다.
get "sec3d", to: "securities/street_page#show"
get "api/sec/street", to: "api/sec_street#show"
# 거리 주소(SEC_STREET 있음)에서는 루트가 곧 증권 거리다. 라우트는 부팅 때 정해지므로
# 켜짐 여부는 요청마다 ENV 로 읽는다. 변수가 없으면 이 줄은 매칭되지 않아 root 가 그대로 받는다.
get "/", to: redirect("/sec3d", status: 302), constraints: ->(_req) { ENV["SEC_STREET"].present? }
