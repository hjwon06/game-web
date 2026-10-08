module Inventory
  # 이미 쓰인 멱등키를 다른 내용(품목·로트·위치·수량·유형·참조)으로 다시 썼다. 기존 이동은 그대로고 새 이동은 없다.
  class IdempotencyConflict < StandardError; end
end
