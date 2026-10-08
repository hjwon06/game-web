# 물량 보정(2단계-③d): 원자재 팔레트가 100 -> 500 개가 돼 칸(팔레트 4개)은 400 -> 2000, 라인 공급대는 800 -> 4000 으로 키운다.
# 새로 만드는 DB 는 Location::ensure_defaults! 가 같은 값으로 만든다. 이미 있는 칸·공급대만 옛 값일 때 바꾼다(손으로 바꾼 값은 건드리지 않는다).
class ScalePalletCapacities < ActiveRecord::Migration[8.1]
  OLD_BIN = 400
  OLD_LINE_SIDE = 800
  NEW_BIN = 2000
  NEW_LINE_SIDE = 4000

  def up
    execute "UPDATE locations SET capacity_units = #{NEW_BIN} WHERE level = 'bin' AND capacity_units = #{OLD_BIN}"
    execute "UPDATE locations SET capacity_units = #{NEW_LINE_SIDE} WHERE code = 'line_side' AND capacity_units = #{OLD_LINE_SIDE}"
  end

  def down
    execute "UPDATE locations SET capacity_units = #{OLD_BIN} WHERE level = 'bin' AND capacity_units = #{NEW_BIN}"
    execute "UPDATE locations SET capacity_units = #{OLD_LINE_SIDE} WHERE code = 'line_side' AND capacity_units = #{NEW_LINE_SIDE}"
  end
end
