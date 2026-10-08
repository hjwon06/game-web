module Inventory
  # 물리 위치(from)의 현재고가 이동 수량보다 적다. 이동은 만들어지지 않는다.
  class InsufficientStock < StandardError; end
end
