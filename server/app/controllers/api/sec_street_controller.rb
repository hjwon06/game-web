# 거리 화면(⑦) 읽기 API. 증권 DB 만 읽는다. 본문은 Securities::StreetRead 가 만든다.
# ETag 는 server_time 을 뺀 본문의 SHA1 이다. 같으면 304(본문 없음).
# state_path · now_source · cache_store 는 테스트가 바꾼다(시계 주입).
module Api
  class SecStreetController < BaseController
    class_attribute :state_path, default: Securities::Sim::Config::STATE_PATH
    class_attribute :now_source, default: -> { Time.current }
    class_attribute :cache_store, default: nil # nil 이면 Rails.cache

    rescue_from Securities::StreetRead::BadCursor do |error|
      render json: { error: "bad_cursor", param: error.param }, status: :bad_request
    end

    def show
      now = now_source.call
      read = Securities::StreetRead.new(state_path: state_path, now: now, cache: cache_store || Rails.cache)
      payload = read.call(after_seq: params[:after_seq], after_exec: params[:after_exec])
      return unless stale?(etag: Digest::SHA1.hexdigest(JSON.generate(payload)))

      render json: { server_time: now.iso8601(3) }.merge(payload)
    end
  end
end
