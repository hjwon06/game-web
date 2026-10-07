# 공장 화면(레포 루트 index.html)을 로그인한 사람에게만 내려준다.
# 파일은 public 이 아니라 여기서만 서빙한다(공개 서빙되면 로그인 우회).
# <base href="/v/{VER}/"> 를 넣어 styles.css·src·data 주소가 파일이 바뀔 때마다 달라지게 한다
# (Cloudflare 가 같은 주소의 옛 사본을 지점별로 쥐고 있어서).
class HomeController < ApplicationController
  ROOT = Rails.root.join("..").expand_path.freeze
  INDEX = ROOT.join("index.html").freeze
  VERSIONED = ["index.html", "styles.css", "src/*.js", "data/*.json"].freeze

  # 기동 시 1회 계산해 둔다(개발 환경은 파일을 고치며 쓰므로 매 요청 다시 계산).
  def self.version
    return compute_version if Rails.env.development?

    @version ||= compute_version
  end

  def self.compute_version
    VERSIONED.flat_map { |g| Dir.glob(ROOT.join(g).to_s) }.map { |f| File.mtime(f).to_i }.max.to_i
  end

  def show
    base = %(<base href="/v/#{self.class.version}/">)
    html = INDEX.read.sub(/<head[^>]*>/i) { "#{$&}\n  #{base}" }
    render html: html.html_safe, layout: false
  end
end
