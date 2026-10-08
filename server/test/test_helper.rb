ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # 위치 9개는 구조 덤프가 아니라 데이터다. fixture 로 넣으면 FK 검증이 superuser 권한을 요구하므로 매 테스트 보장한다.
    setup { Location.ensure_defaults!; Resource.ensure_defaults! }

    # Add more helper methods to be used by all tests here...
  end
end

# 기계 속도를 배율 없이(RATES 그대로) 가정하고 숫자를 박아 둔 테스트용. RATE_SCALE 을 1.0 으로 고정했다가 끝나면 되돌린다.
# 배율 자체는 simulation/config_test.rb 가 기본값으로 검사한다. 테스트는 프로세스 병렬이라 상수를 바꿔도 서로 섞이지 않는다.
module UnscaledRatesHelper
  def self.included(base)
    base.setup { UnscaledRatesHelper.set(1.0) }
    base.teardown { UnscaledRatesHelper.set(UnscaledRatesHelper::ORIGINAL) }
  end

  ORIGINAL = Simulation::Config::RATE_SCALE

  def self.set(value)
    Simulation::Config.send(:remove_const, :RATE_SCALE)
    Simulation::Config.const_set(:RATE_SCALE, value)
  end
end

# 지게차 진입 제한(FORKLIFT_ADMIT_SECONDS)이 목적이 아닌 테스트용. 한 번에 여러 건을 계획하는 것을 전제하므로 상한을 사실상 없앴다가 끝나면 되돌린다.
# 진입 제한 자체는 simulation/forklift_admit_test.rb 가 기본값으로 검사한다.
module UnlimitedForkliftQueueHelper
  ORIGINAL = Simulation::Config::FORKLIFT_ADMIT_SECONDS

  def self.included(base)
    base.setup { UnlimitedForkliftQueueHelper.set(1_000_000) }
    base.teardown { UnlimitedForkliftQueueHelper.set(UnlimitedForkliftQueueHelper::ORIGINAL) }
  end

  def self.set(value)
    Simulation::Config.send(:remove_const, :FORKLIFT_ADMIT_SECONDS)
    Simulation::Config.const_set(:FORKLIFT_ADMIT_SECONDS, value)
  end
end

module AuthHelper
  TEST_PASSWORD = "factory-pass-1".freeze

  def create_user(name: "jay", password: TEST_PASSWORD)
    User.create!(name: name, password: password, password_confirmation: password)
  end

  # 실제 로그인 요청으로 세션 쿠키를 받는다(쿠키 서명을 흉내 내지 않는다).
  def sign_in_as(user, password: TEST_PASSWORD)
    post "/login", params: { name: user.name, password: password }
    assert_redirected_to "/"
  end
end

ActionDispatch::IntegrationTest.include AuthHelper
