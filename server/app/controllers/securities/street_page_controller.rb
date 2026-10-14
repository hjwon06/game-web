# 증권 거리 화면(레포 루트 sec3d.html)을 로그인한 사람에게만 내려준다.
# HomeController 와 같은 방식이다(복사해 쓰고 HomeController 는 건드리지 않는다): 파일은 public 이 아니라 여기서만 서빙하고,
# <base href="/v/{VER}/"> 를 넣어 src/s3d · src/c3d 주소가 파일이 바뀔 때마다 달라지게 한다.
module Securities
  class StreetPageController < ApplicationController
    ROOT = Rails.root.join("..").expand_path.freeze
    VERSIONED = ["sec3d.html", "src/s3d/*.js", "src/c3d/*.js"].freeze

    class_attribute :page, default: ROOT.join("sec3d.html") # 테스트가 바꾼다

    def self.version
      return compute_version if Rails.env.development?

      @version ||= compute_version
    end

    def self.compute_version
      VERSIONED.flat_map { |g| Dir.glob(ROOT.join(g).to_s) }.map { |f| File.mtime(f).to_i }.max.to_i
    end

    # 화면 파일이 아직 없으면 500 이 아니라 404 다.
    def show
      return head(:not_found) unless page.file?

      render_with_base page
    end

    private

    def render_with_base(file)
      base = %(<base href="/v/#{self.class.version}/">)
      html = file.read.sub(/<head[^>]*>/i) { "#{$&}\n  #{base}" }
      render html: html.html_safe, layout: false
    end
  end
end
