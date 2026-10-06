module Api
  class CommandsController < BaseController
    def create
      result = MachineCommand.call(
        idempotency_key: params[:idempotency_key], machine_code: params[:machine_code],
        kind: params[:kind], base_version: params[:base_version]
      )
      render json: { result_status: result.status, machine: machine_payload(result.machine) },
             status: result.status
    end

    private

    def machine_payload(machine)
      machine && { code: machine.code, state: machine.state, version: machine.version }
    end
  end
end
