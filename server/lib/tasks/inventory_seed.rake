# 재고 시드. 재실행 안전: 마스터는 find_or_create, 이동은 고정 멱등키라 두 번째부터는 아무것도 만들지 않는다.
# 모든 재고 변동은 Inventory::Move(Inspect·Ship 포함) 경유다. quants 에 직접 INSERT 하지 않는다.
# 전제: 작업지시(WO-1001~1004)가 먼저 있어야 한다(db/seeds.rb 가 기계·작업지시를 만든 뒤 이 태스크를 부른다).
#
# 가정: 자재는 로트 없이(lot nil) 들어온다 — Inventory::Backflush 가 BOM 자재를 lot nil 로 출고하기 때문이다.
#       로트는 완제품에만 있다(품목당 6개 x 4품목 = 24).
module InventorySeed
  # [sku, 이름, 입고 1회 수량]. 단위는 전부 ea.
  RAW = [
    ["RAW-STEEL", "강판 시트", 1000],
    ["RAW-BOLT",  "볼트 M8",   1000],
    ["RAW-PACK",  "고무 패킹", 400]
  ].freeze

  # [sku, 이름(= work_orders.product 문자열), BOM { 자재 sku => 단위당 수량 }]
  FG = [
    ["FG-BRACKET-A", "브래킷 A",   { "RAW-STEEL" => 2, "RAW-BOLT" => 4 }],
    ["FG-HOUSING-B", "하우징 B",   { "RAW-STEEL" => 3, "RAW-PACK" => 2 }],
    ["FG-PLATE-C",   "플레이트 C", { "RAW-STEEL" => 1, "RAW-BOLT" => 2 }],
    ["FG-SHAFT-D",   "샤프트 D",   { "RAW-STEEL" => 2, "RAW-PACK" => 1, "RAW-BOLT" => 2 }]
  ].freeze

  RECEIPTS = 3            # 자재별 입고 횟수. 마지막 1회분은 입고대에 남긴다(적치 2회).
  PUTAWAY_RECEIPTS = 2
  LOTS_PER_FG = 6
  BATCH_QTY = 40          # 로트당 생산량
  FAIL_QTY = 2            # 로트 번호가 3의 배수면 불합격 2개

  # [수주번호, 고객, 완제품 sku, 주문량, [[로트 번호, 출하량], ...]]
  # 로트별 출하 합계가 합격 수량(40, 불합격 있는 로트는 38)을 넘지 않게 고정해 둔다.
  # 현재고를 보고 로트를 고르면 재실행 때 계획이 달라져 중복 출하가 생기므로 계획 자체를 상수로 둔다.
  ORDERS = [
    ["SO-2610-001", "한빛정공",   "FG-BRACKET-A", 100, [[1, 40], [2, 30]]], # 100 중 70 출하 = partial
    ["SO-2610-002", "대성기계",   "FG-BRACKET-A",  50, [[2, 10], [4, 40]]],
    ["SO-2610-003", "서진산업",   "FG-HOUSING-B",  80, [[1, 40], [2, 40]]],
    ["SO-2610-004", "한빛정공",   "FG-HOUSING-B",  30, [[4, 30]]],
    ["SO-2610-005", "대성기계",   "FG-PLATE-C",    60, [[1, 40], [2, 20]]],
    ["SO-2610-006", "미래오토",   "FG-SHAFT-D",    90, [[1, 40], [2, 40], [3, 10]]],
    ["SO-2610-007", "서진산업",   "FG-SHAFT-D",    45, [[5, 40], [6, 5]]],
    ["SO-2610-008", "미래오토",   "FG-PLATE-C",    40, [[4, 40]]],
    ["SO-2610-009", "대성기계",   "FG-BRACKET-A", 120, []],                 # open
    ["SO-2610-010", "한빛정공",   "FG-HOUSING-B", 200, []]                  # open
  ].freeze

  module_function

  def run
    Location.ensure_defaults!
    raws = RAW.to_h { |sku, name, _| [sku, product(sku, name, "raw")] }
    fgs = FG.to_h { |sku, name, _| [sku, product(sku, name, "fg")] }

    FG.each do |sku, _, bom|
      bom.each do |raw_sku, qty_per|
        BomLine.find_or_create_by!(product: fgs.fetch(sku), component: raws.fetch(raw_sku)) { |b| b.qty_per = qty_per }
      end
    end

    seed_open_order_boms(raws)

    receive_raw(raws)
    lots = produce_fg(raws, fgs)
    ship_orders(fgs, lots)

    puts "inventory:seed 품목 #{Product.count} / 로트 #{Lot.count} / 이동 #{StockMove.count} / 수주 #{SalesOrder.count}"
  end

  # work_orders.product 와 같은 정규화(공백 접기 + 소문자)로 기존 품목을 먼저 찾는다.
  # 작업지시가 만든 품목(AUTO-sku)이 이미 있으면 새로 만들지 않고 재사용한다.
  def product(sku, name, kind)
    Product.where("lower(regexp_replace(btrim(name), '\\s+', ' ', 'g')) = ?", name.squish.downcase).first ||
      Product.create!(sku: sku, name: name, uom: "ea", kind: kind)
  end

  # 끝나지 않은(active·queued) 작업지시의 완제품 중 BOM 이 하나도 없는 것에 자재 1~2개를 붙인다.
  # 품목 id 로 자재·수량을 정하므로 재실행해도 같은 결과이고, 이미 BOM 이 있는 품목은 건드리지 않는다.
  # 자재는 기존 raw 3종을 재사용한다(새 품목 없음). 자재 순서는 sku 정렬.
  def seed_open_order_boms(raws)
    materials = raws.sort.map(&:last)
    Product.where(kind: "fg", id: WorkOrder.where(status: %w[active queued]).select(:product_id))
           .where.not(id: BomLine.select(:product_id)).order(:id).each do |p|
      count = p.id.even? ? 2 : 1
      count.times do |i|
        BomLine.find_or_create_by!(product: p, component: materials[(p.id + i) % materials.size]) do |b|
          b.qty_per = ((p.id + i) % 3) + 1
        end
      end
    end
  end

  def move(**args)
    Inventory::Move.call(ref: nil, **args)
  end

  def receive_raw(raws)
    RAW.each do |sku, _, qty|
      p = raws.fetch(sku)
      (1..RECEIPTS).each do |n|
        move(product: p, lot: nil, from: "supplier", to: "receiving", qty: qty, move_type: "receive",
             idempotency_key: "seed:receive:#{sku}:#{n}")
      end
      (1..PUTAWAY_RECEIPTS).each do |n|
        move(product: p, lot: nil, from: "receiving", to: "raw_store", qty: qty, move_type: "putaway",
             idempotency_key: "seed:putaway:#{sku}:#{n}")
      end
    end
  end

  # { [sku, 로트 번호] => Lot }
  def produce_fg(raws, fgs)
    lots = {}
    FG.each do |sku, _, bom|
      p = fgs.fetch(sku)
      work_order = WorkOrder.where(product_id: p.id).order(:id).first or
        raise "#{p.name} 작업지시가 없다. db:seed 로 기계·작업지시를 먼저 만든다"

      (1..LOTS_PER_FG).each do |i|
        lot = Lot.find_or_create_by!(product: p, lot_no: format("LOT-%s-%02d", sku.delete_prefix("FG-"), i))
        lots[[sku, i]] = lot

        bom.sort.each do |raw_sku, qty_per|
          move(product: raws.fetch(raw_sku), lot: nil, from: "raw_store", to: "production",
               qty: qty_per * BATCH_QTY, move_type: "issue", idempotency_key: "seed:issue:#{lot.lot_no}:#{raw_sku}")
        end
        move(product: p, lot: lot, from: "production", to: "qc", qty: BATCH_QTY, move_type: "produce",
             idempotency_key: "seed:produce:#{lot.lot_no}")

        fail_qty = (i % 3).zero? ? FAIL_QTY : 0
        Inventory::Inspect.call(lot: lot, work_order: work_order, pass_qty: BATCH_QTY - fail_qty, fail_qty: fail_qty,
                                idempotency_key: "seed:qc:#{lot.lot_no}")
      end
    end
    lots
  end

  def ship_orders(fgs, lots)
    ORDERS.each_with_index do |(so_no, customer, sku, ordered, plan), n|
      order = SalesOrder.find_or_create_by!(so_no: so_no) do |o|
        o.customer = customer
        o.due_date = Date.new(2026, 11, 1) + n
      end
      line = SalesOrderLine.find_or_create_by!(sales_order: order, product: fgs.fetch(sku)) { |l| l.ordered_qty = ordered }

      plan.each do |lot_idx, qty|
        lot = lots.fetch([sku, lot_idx])
        Inventory::Ship.call(sales_order_line: line, lot: lot, qty: qty, idempotency_key: "seed:ship:#{so_no}:#{lot.lot_no}")
      end
    end
  end
end

namespace :inventory do
  desc "재고 시드(품목·BOM·로트·수주·이동). 재실행 안전"
  task seed: :environment do
    InventorySeed.run
  end
end
