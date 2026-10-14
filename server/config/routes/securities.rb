# 증권 거리 화면(⑦). config/routes.rb 가 draw :securities 로 읽는다.
get "sec3d", to: "securities/street_page#show"
get "api/sec/street", to: "api/sec_street#show"
