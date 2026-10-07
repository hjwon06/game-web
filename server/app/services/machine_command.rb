# 기계 상태 전이 명령의 유일한 진입점. 상태 전이 로직은 이 파일에만 둔다.
class MachineCommand
  Result = Struct.new(:status, :machine, keyword_init: true)

  UUID_FORMAT = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
  TARGET = { "start" => "running", "stop" => "stopped", "break" => "broken", "repair" => "stopped" }.freeze
  ALLOWED_FROM = {
    "start" => %w[stopped],
    "stop" => %w[running],
    "break" => %w[running stopped],
    "repair" => %w[broken]
  }.freeze

  def self.call(**args)
    new(**args).call
  end

  def initialize(idempotency_key:, machine_code:, kind:, base_version:)
    @key = idempotency_key.to_s
    @machine_code = machine_code.to_s
    @kind = kind.to_s
    @base_version = parse_version(base_version)
  end

  def call
    return Result.new(status: 422, machine: nil) unless valid_input?

    Machine.transaction do
      lock_key # 같은 키 요청을 직렬화한다. 먼저 온 쪽이 커밋하면 뒤 요청의 조회가 그 행을 본다.
      stored = Command.find_by(idempotency_key: @key) # 기계 조회보다 먼저: 같은 키·다른 내용은 없는 기계여도 422
      machine = Machine.find_by(code: @machine_code)
      next replay(machine&.id, stored) if stored
      next Result.new(status: 404, machine: nil) unless machine

      run(machine.id)
    end
  end

  private

  def lock_key
    sql = ApplicationRecord.sanitize_sql(["SELECT pg_advisory_xact_lock(hashtext(?))", @key])
    ApplicationRecord.connection.execute(sql)
  end

  # 잠금 순서는 모든 경로에서 "advisory(키) → machines 행" 하나뿐이다. 기록(commands INSERT)은 그 뒤에 한다.
  # commands INSERT 의 FK 검사는 machines 행에 FOR KEY SHARE 를 잡고 트랜잭션 끝까지 쥔다.
  # INSERT 를 FOR UPDATE 앞에 두면 같은 기계로 온 두 요청이 각자 KEY SHARE 를 쥔 채 서로의 FOR UPDATE 를
  # 기다려 교착(deadlock detected → 500)이 난다. FOR UPDATE 를 먼저 잡으면 뒤 요청은 INSERT 이전에 줄을 선다.
  def run(machine_id)
    machine = Machine.lock.find(machine_id)                       # ① FOR UPDATE
    command_id = insert_command(machine_id)                       # ② KEY SHARE 는 이미 쥔 행 잠금에 포함된다
    return replay(machine_id) unless command_id

    return finish(command_id, machine, 409) if @base_version != machine.version # ③
    return finish(command_id, machine, 200) if machine.state == TARGET[@kind]   # 이미 목표 상태: no-op
    return finish(command_id, machine, 422) unless ALLOWED_FROM[@kind].include?(machine.state) # ④

    transition(command_id, machine)                               # ⑤
    finish(command_id, machine, 200)
  end

  # 충돌(같은 키 재요청)이면 nil. 동시 요청이면 먼저 온 쪽이 커밋할 때까지 여기서 대기한다.
  def insert_command(machine_id)
    row = { idempotency_key: @key, machine_id: machine_id, kind: @kind,
            base_version: @base_version, created_at: Time.current }
    Command.insert(row, unique_by: :idempotency_key, returning: %w[id]).rows.dig(0, 0)
  end

  # 같은 키를 다른 내용으로 재사용하면 원래 결과를 돌려주지 않고 422 로 거절한다. 기존 행은 건드리지 않는다.
  def replay(machine_id, stored = Command.find_by!(idempotency_key: @key))
    return Result.new(status: 422, machine: machine_id && Machine.find(machine_id)) unless same_request?(stored, machine_id)

    Result.new(status: stored.result_status, machine: Machine.find(stored.machine_id))
  end

  def same_request?(stored, machine_id)
    stored.machine_id == machine_id && stored.kind == @kind && stored.base_version == @base_version
  end

  def transition(command_id, machine)
    from_state = machine.state
    machine.update!(state: TARGET[@kind], version: machine.version + 1)
    MachineStateEvent.create!(machine: machine, command_id: command_id, from_state: from_state,
                              to_state: machine.state, version: machine.version, at: Time.current)
  end

  # 409/422 도 롤백하지 않고 기록한 채 커밋한다. 재시도가 같은 결과를 받아야 한다.
  def finish(command_id, machine, status)
    Command.where(id: command_id).update_all(result_status: status)
    Result.new(status: status, machine: machine)
  end

  def valid_input?
    UUID_FORMAT.match?(@key) && Command::KINDS.include?(@kind) && !@base_version.nil?
  end

  def parse_version(value)
    return value if value.is_a?(Integer) && value >= 0

    Integer(value, 10) if value.is_a?(String) && value.match?(/\A\d+\z/)
  end
end
