module Api
  class MeController < BaseController
    def show
      render json: { name: Current.user.name }
    end
  end
end
