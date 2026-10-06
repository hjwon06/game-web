# ApplicationController 를 상속하지 않는다. allow_browser·importmap etag 는 JSON API 에 맞지 않는다.
# 인증은 없다 (Cloudflare Access 뒤에 둔다).
module Api
  class BaseController < ActionController::Base
    skip_forgery_protection
  end
end
