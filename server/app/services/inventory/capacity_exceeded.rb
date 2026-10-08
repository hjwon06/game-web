module Inventory
  # 도착 칸(capacity_units 가 있는 위치)의 현재고 합 + 이동 수량이 용량을 넘는다. 이동은 만들어지지 않는다.
  class CapacityExceeded < StandardError; end
end
