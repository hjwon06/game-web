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
