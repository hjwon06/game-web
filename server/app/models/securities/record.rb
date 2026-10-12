# 증권 가상 시장 모델의 부모. 공장 DB(primary)가 아니라 securities DB 에 붙는다.
# 모델 9개는 전부 이 클래스를 상속해야 securities 연결을 탄다(상속을 빠뜨리면 primary 에서 테이블을 찾는다).
module Securities
  class Record < ActiveRecord::Base
    self.abstract_class = true

    connects_to database: { writing: :securities, reading: :securities }
  end
end
