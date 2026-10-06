module Api
  class StateController < BaseController
    def show
      machines = Machine.order(:code).to_a
      version = machines.sum(&:version)
      return unless stale?(etag: [version, machines.size], template: false)

      render json: { version: version, machines: machines.map { |m| payload(m) } }
    end

    private

    def payload(machine)
      { code: machine.code, name: machine.name, state: machine.state, version: machine.version }
    end
  end
end
