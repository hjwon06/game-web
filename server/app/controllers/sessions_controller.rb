class SessionsController < ApplicationController
  allow_unauthenticated_access
  layout "auth"

  def new
    redirect_to setup_path if User.none?
  end

  def create
    creds = params.fetch(:user, params)
    user = User.find_by(name: creds[:name].to_s.strip)
    if user&.authenticate(creds[:password].to_s)
      start_new_session_for(user)
      redirect_to root_path
    else
      @error = "이름 또는 비밀번호가 맞지 않습니다"
      render :new, status: :unprocessable_entity
    end
  end

  # 상단 바 링크(GET)와 DELETE 모두 받는다.
  def destroy
    resume_session
    terminate_session
    redirect_to login_path
  end
end
