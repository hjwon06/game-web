# 계정이 하나도 없을 때만 열리는 첫 계정 화면. 1인용이라 동시 생성 레이스는 막지 않는다.
class SetupController < ApplicationController
  allow_unauthenticated_access
  before_action :redirect_unless_empty
  layout "auth"

  def new
    @user = User.new
  end

  def create
    attrs = params.fetch(:user, params)
    @user = User.new(name: attrs[:name], password: attrs[:password],
                     password_confirmation: attrs[:password_confirmation])
    if @user.save
      start_new_session_for(@user)
      redirect_to root_path
    else
      render :new, status: :unprocessable_entity
    end
  end

  private
    def redirect_unless_empty
      redirect_to login_path if User.exists?
    end
end
