module Api
  class HudController < BaseController
    LAST_MINUTE = 60.seconds
    DEFECT_WINDOW = 10.minutes

    # 창이 시간에 따라 밀리므로 ETag 는 상태 버전이 아니라 본문 해시로 만든다.
    def show
      body = payload(Time.current)
      return unless stale?(etag: Digest::SHA1.hexdigest(body.to_json), template: false)

      render json: body
    end

    private

    def payload(now)
      machines = Machine.order(:id).to_a
      ids = machines.map(&:id)
      orders = WorkOrder.where(machine_id: ids, status: "active").index_by(&:machine_id)
      recent = recent_buckets(ids, now - LAST_MINUTE)
      { machines: machines.map { |m| machine_payload(m, orders[m.id], recent[m.id]) },
        defect_ratio_10m: defect_ratio(ids, now - DEFECT_WINDOW),
        broken: machines.select { |m| m.state == "broken" }.map(&:code) }
    end

    # machine_id 를 함께 걸어야 (machine_id, bucket_start) 인덱스를 탄다.
    def recent_buckets(ids, since)
      ProductionEvent.where(machine_id: ids, bucket_start: since..)
                     .group(:machine_id).pluck(:machine_id, Arel.sql("SUM(good_qty)"), Arel.sql("COUNT(*)"))
                     .to_h { |id, good, buckets| [id, [good.to_i, buckets.to_i]] }
    end

    def defect_ratio(ids, since)
      good, defect = ProductionEvent.where(machine_id: ids, bucket_start: since..)
                                    .pick(Arel.sql("COALESCE(SUM(good_qty), 0)"), Arel.sql("COALESCE(SUM(defect_qty), 0)"))
      total = good.to_i + defect.to_i
      total.zero? ? nil : (defect.to_f / total).round(4)
    end

    def machine_payload(machine, order, recent)
      good, buckets = recent || [0, 0]
      { code: machine.code, state: machine.state, work_order: order_payload(order),
        last_minute_good: good, last_minute_buckets: buckets }
    end

    def order_payload(order)
      order && { code: order.code, product: order.product, target_qty: order.target_qty,
                 produced_qty: order.produced_qty }
    end
  end
end
