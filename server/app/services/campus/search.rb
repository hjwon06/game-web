module Campus
  # 관제 검색: 발주·수주 번호, 자원 코드(지게차·도크), 칸 코드, 품목명을 부분 일치(대소문자 무시)로 찾아 최대 8건.
  # 유형 순서(po → so → resource → bin → product)대로 채우고 8건이 차면 뒤 유형은 묻지 않는다. 쿼리는 최대 5개.
  # building 은 화면이 카메라를 보낼 건물이다. 발주·수주는 사무동(office), 자원·칸은 위치의 건물, 품목은 종류별 기본 건물이다.
  class Search
    LIMIT = 8
    Q_MAX = 40
    RESOURCE_LABEL = { "forklift" => "지게차", "dock_in" => "입고 도크", "dock_out" => "출하 도크" }.freeze
    PRODUCT_BUILDING = { "raw" => "material", "wip" => "hall", "fg" => "shipping_wh" }.freeze
    OFFICE = "office".freeze
    RESOURCE_HOME_DEFAULT = "hall".freeze

    # rows: Location.pluck(:id, :code, :parent_id) 전체.
    def self.call(q:, rows:) = new(q: q, rows: rows).call

    def initialize(q:, rows:)
      @q = q.to_s.strip[0, Q_MAX]
      @building_of = Location.buildings_by_id(rows)
    end

    def call
      return [] if @q.empty?

      pattern = "%#{ApplicationRecord.sanitize_sql_like(@q)}%"
      out = []
      %i[orders sales resources bins products].each do |step|
        break if out.size >= LIMIT

        out.concat(send(step, pattern, LIMIT - out.size))
      end
      out
    end

    private

    def orders(pattern, limit)
      PurchaseOrder.joins(:supplier).where("purchase_orders.po_no ILIKE ?", pattern)
                   .order("purchase_orders.ordered_at DESC", "purchase_orders.id DESC").limit(limit)
                   .pluck("purchase_orders.po_no", "suppliers.name")
                   .map { |no, supplier| { type: "po", code: no, label: supplier, building: OFFICE } }
    end

    def sales(pattern, limit)
      SalesOrder.where("so_no ILIKE ?", pattern).order(created_at: :desc, id: :desc).limit(limit).pluck(:so_no, :customer)
                .map { |no, customer| { type: "so", code: no, label: customer, building: OFFICE } }
    end

    def resources(pattern, limit)
      Resource.where(kind: RESOURCE_LABEL.keys).where("code ILIKE ?", pattern).order(:code).limit(limit).pluck(:code, :kind, :home_location_id)
              .map { |code, kind, home| { type: "resource", code: code, label: RESOURCE_LABEL.fetch(kind), building: home ? @building_of[home] : RESOURCE_HOME_DEFAULT } }
    end

    def bins(pattern, limit)
      Location.where(level: "bin").where("code ILIKE ?", pattern).order(:code).limit(limit).pluck(:id, :code, :name)
              .map { |id, code, name| { type: "bin", code: code, label: name, building: @building_of[id] } }
    end

    def products(pattern, limit)
      Product.where("name ILIKE ?", pattern).order(:name, :id).limit(limit).pluck(:sku, :name, :kind)
             .map { |sku, name, kind| { type: "product", code: sku, label: name, building: PRODUCT_BUILDING[kind] } }
    end
  end
end
