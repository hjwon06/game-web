# 화면 정적 파일(/v/:ver/...)을 레포 루트에서 내려준다.
# ver 는 주소만 바꾸는 용도라 검사하지 않는다(Cloudflare 가 옛 사본을 못 쥐게).
# 파일은 소스이므로 로그인 없이 열린다. 허용 목록 밖은 전부 404.
class StaticController < ActionController::Base
  # .js 를 GET 으로 내려주면 Rails 가 교차 출처 스크립트 보호로 422 를 낸다. 공개 소스 파일이라 끈다.
  skip_forgery_protection

  ROOT = Rails.root.join("..").expand_path.to_s.freeze
  PREFIXES = %w[src/ data/ assets/ vendor/ mock/].freeze
  EXACT = %w[styles.css].freeze
  TYPES = {
    ".js" => "text/javascript",
    ".css" => "text/css",
    ".json" => "application/json",
    ".png" => "image/png",
    ".html" => "text/html"
  }.freeze

  def show
    file = resolve(params[:path].to_s)
    return head(:not_found) unless file

    response.headers["Cache-Control"] = "no-store"
    send_file file, type: TYPES.fetch(File.extname(file).downcase, "application/octet-stream"),
                    disposition: "inline"
  end

  private

  def resolve(path)
    return if path.empty? || path.include?("\0") || path.include?("..") || path.start_with?("/")
    return unless EXACT.include?(path) || PREFIXES.any? { |p| path.start_with?(p) }

    full = File.expand_path(path, ROOT)
    return unless full.start_with?("#{ROOT}/") && File.file?(full)

    # 심볼릭 링크로 레포 밖을 가리키는 경우도 막는다
    real = File.realpath(full)
    real if real.start_with?("#{File.realpath(ROOT)}/")
  end
end
