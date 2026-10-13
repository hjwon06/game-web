require "test_helper"

# 단일가 가격 결정(순수 계산). 입력은 [가격 또는 nil(시장가), 잔량] 쌍이다. DB 를 쓰지 않는다.
# 변이 검사: 체결량 최대 대신 첫 후보를 고르면 T1 이 실패하고, |수요 − 공급| 규칙을 빼면 T1 (가) 가 실패한다.
class Securities::AuctionPriceTest < ActiveSupport::TestCase
  def price(buys:, sells:, base: 50_000)
    Securities::AuctionPrice.call(buys: buys, sells: sells, base_price: base)
  end

  test "T1 체결량 최대: 매수 51,000×3 · 50,500×2 · 50,000×5, 매도 49,500×4 · 50,000×3 · 50,500×5 → 50,000 에 7주" do
    result = price(buys: [[51_000, 3], [50_500, 2], [50_000, 5]], sells: [[49_500, 4], [50_000, 3], [50_500, 5]])

    assert_equal [50_000, 7], result
  end

  test "T1 (가) 체결량이 같으면 |수요 − 공급| 이 작은 가격: 50,000(차 1) 이 50,500(차 3) 을 이긴다" do
    result = price(buys: [[50_500, 4], [50_000, 1]], sells: [[50_000, 4], [50_500, 3]], base: 50_500)

    assert_equal [50_000, 4], result # 기준가에 가까운 쪽(50,500)을 먼저 보면 틀린다
  end

  test "T1 (나) 체결량 · 차이가 같으면 기준가에 가까운 쪽: 50,500" do
    result = price(buys: [[50_500, 4], [50_000, 2]], sells: [[50_000, 4], [50_500, 2]], base: 50_500)

    assert_equal [50_500, 4], result
  end

  test "시장가: 수요 · 공급에 항상 들어가고 후보 가격은 못 만든다(기준가만 후보)" do
    assert_equal [50_000, 2], price(buys: [[nil, 5]], sells: [[nil, 2]])
    assert_equal [49_500, 3], price(buys: [[nil, 3]], sells: [[49_500, 3]], base: 49_500)
  end

  test "교차하지 않으면 nil 이다(매수 최고가 < 매도 최저가 · 한쪽이 비어 있음)" do
    assert_nil price(buys: [[49_000, 5]], sells: [[51_000, 5]])
    assert_nil price(buys: [[50_000, 5]], sells: [])
    assert_nil price(buys: [], sells: [])
  end
end
