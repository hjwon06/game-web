module Api
  # 관제 검색 박스용. 입력할 때마다 부르므로 쿼리는 위치 1개 + 유형별 최대 5개로 고정이다.
  class CampusSearchController < BaseController
    def show
      rows = Location.pluck(:id, :code, :parent_id)
      render json: { results: ::Campus::Search.call(q: params[:q], rows: rows) }
    end
  end
end
