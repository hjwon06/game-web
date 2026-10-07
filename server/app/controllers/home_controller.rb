# 공장 화면(레포 루트 index.html)을 로그인한 사람에게만 내려준다.
# 파일은 public 이 아니라 여기서만 서빙한다(공개 서빙되면 로그인 우회).
class HomeController < ApplicationController
  INDEX = Rails.root.join("..", "index.html").freeze

  def show
    send_file INDEX, type: "text/html", disposition: "inline"
  end
end
