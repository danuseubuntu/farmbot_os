alias Farmbot.BotState.Monitor.State, as: BotState
alias Farmbot.BotState.Hardware.State, as: HardwareState
defmodule Sequence.VM do
  @moduledoc """
    There should only ever be one instance of this process at a time.
  """
  require Logger

  defmodule BotStateTracker do
    @moduledoc false
    use GenEvent
    require Logger

    # when state is updated
    def handle_event({:dispatch, %BotState{hardware: hardware}},{parent, old_state})
    when hardware != old_state do
      GenServer.cast(parent, hardware)
      {:ok, {parent, hardware}}
    end

    # when state hasnt changed, just ignore it
    def handle_event({:dispatch, _},{parent, old_state}) do
      {:ok, {parent, old_state}}
    end

    def handle_call(:state, {parent, nil}) do
      Logger.error("THIS WILL NOT END WELL")
      {:ok, :find_me, {parent, nil}}
    end

    def handle_call(:state, {parent, old_state}) do
      {:ok, old_state, {parent, old_state}}
    end

    def terminate(_, _) do
      Logger.debug("Sequence BotState Tracker stopping.")
    end
  end

  def get_status do
    GenEvent.call(BotStateEventManager, BotStateTracker, :state) |> check_status
  end

  def check_status(%HardwareState{} = blah), do: blah
  def check_status(_), do: get_status

  def start_link(%Sequence{} = sequence) do
    GenServer.start_link(__MODULE__,sequence)
  end

  def init(%Sequence{} = sequence) do
    Farmbot.BotState.Monitor.add_handler(BotStateTracker, {__MODULE__, nil})
    tv = Map.get(sequence.args, "tag_version") || 0
    module = Module.concat(Sequence, "InstructionSet_#{tv}")
    {:ok, instruction_set} = module.start_link(self())
    tick(self(), :done)
    status = get_status
    initial_state =
      %{
        status: status,
        instruction_set: instruction_set,
        vars: %{},
        running: true,
        sequence: sequence,
        steps: {sequence.body, []}
       }
    {:ok, initial_state}
  end

  def handle_call({:set_var, identifier, value}, _from, state) do
    new_vars = Map.put(state.vars, identifier, value)
    new_state = Map.put(state, :vars, new_vars )
    {:reply, :ok, new_state}
  end

  def handle_call({:get_var, identifier}, _from, state ) do
    v = Map.get(state.vars, identifier, :error)
    {:reply, v, state}
  end

  def handle_call(:name, _from, state) do
    {:reply, state.sequence.name, state}
  end

  # disabling this right now
  def handle_call(:get_all_vars, _from, state ) do
    # %Farmbot.BotState.Hardware.State{location: [-1, -1, -1], mcu_params: %{}, pins: %{}}
    # Kind of dirty function to make mustache work properly.
    # Also possibly a huge memory leak.

    # get all of the local vars from the vm. # SUPER UNSAFE
    thing1 = state.vars
    |> Enum.reduce(%{}, fn ({key, val}, acc) ->
         Map.put(acc, String.to_atom(key), val)
       end)

    # put current position into the Map
    pins =
    state.status.pins
    |> Enum.reduce(%{}, fn( {key, %{mode: _mode, value: val}}, acc) ->
      # THIS IS SO UNSAFE
      Map.put(acc, String.to_atom("pin"<>key), val)
    end)
    [x,y,z] = state.status.location
    thing2 = Map.merge(%{x: x, y: y, z: z }, pins)

    # gets a couple usefull things out of Farmbot.Sync
    thing3 = Farmbot.Sync.get_users
    |> List.first
    |> Map.drop([:__struct__]) # This probably isnt correct

    # Combine all the things.
    all_things = Map.merge(thing1, thing2)
    |> Map.merge(thing3)
    {:reply, all_things , state}
  end

  def handle_call(:pause, _from, state) do
    {:reply, self(), Map.put(state, :running, false)}
  end

  def handle_call(thing, _from, state) do
    Farmbot.Logger.log("#{inspect thing} is probably not implemented",
      [:warning_toast], [state.sequence.name])
    {:reply, :ok, state}
  end

  def handle_cast(:resume, state) do
    handle_info(:run_next_step, Map.put(state, :running, true))
  end

  def handle_cast(%HardwareState{} = hardware_state, state) do
    {:noreply, Map.put(state, :status, hardware_state)}
  end

  # if the VM is paused
  def handle_info(:run_next_step, %{
          sequence: sequence,
          steps: steps,
          status: status,
          instruction_set: instruction_set,
          vars: vars,
          running: false
         })
  do
    {:noreply,
      %{status: status, sequence: sequence, steps: steps,
        instruction_set: instruction_set, vars: vars, running: false  }}
  end

  # if there is no more steps to run
  def handle_info(:run_next_step, %{
          status: status,
          sequence: sequence,
          instruction_set: instruction_set,
          vars: vars,
          running: running,
          steps: {[], finished_steps}
         })
  do
    Logger.debug("sequence done")
    Farmbot.Logger.log("Sequence Complete", [], [sequence.name])
    send(Sequence.Manager, {:done, self(), sequence})
    Logger.debug("Stopping VM")
    {:noreply,
      %{status: status,
        sequence: sequence,
        steps: {[], finished_steps},
        instruction_set: instruction_set,
        vars: vars,
        running: running  }}
  end

  # if there are more steps to run
  def handle_info(:run_next_step, %{
          status: status,
          instruction_set: instruction_set,
          vars: vars,
          running: true,
          sequence: sequence,
          steps: {more_steps, finished_steps} })
  do
    ast_node = List.first(more_steps)
    kind = Map.get(ast_node, "kind")
    Logger.debug("doing: #{kind}")
    Farmbot.Logger.log("Doing step: #{kind}", [], [sequence.name])
    GenServer.cast(instruction_set, ast_node)
    {:noreply, %{
            status: status,
            sequence: sequence,
            steps: {more_steps -- [ast_node], finished_steps ++ [ast_node]},
            instruction_set: instruction_set,
            vars: vars,
            running: true }}
  end

  def handle_info({:error, :e_stop}, state) do
    Farmbot.Logger.log("Bot in E STOP MODE", [:error], [state.sequence.name])
    send(Sequence.Manager, {:done, self(), state.sequence})
    {:noreply, state}
  end

  def handle_info({:error, error}, state) do
    Farmbot.Logger.log("ERROR: #{inspect(error)}", [:error], [state.sequence.name])
    send(Sequence.Manager, {:done, self(), state.sequence})
    {:noreply, state}
  end

  # the last command was successful
  def tick(vm, :done) do
    Process.send_after(vm, :run_next_step, 100)
    {:noreply, vm}
  end

  # i suck
  def tick(vm, :timeout) do
    seq_name = GenServer.call(vm, :name)
    Farmbot.Logger.log("Command timed out!", [:warning_toast], [seq_name])
    tick(vm, :done)
  end
  def tick(vm, {:error, reason}), do: tick(vm, reason)

  # The last command was not successful
  def tick(vm, error) do
    Process.send_after(vm, {:error, error}, 100)
    {:noreply, vm}
  end

  def terminate(:normal, state) do
    GenServer.stop(state.instruction_set, :normal)
    Farmbot.BotState.Monitor.remove_handler(__MODULE__)
  end

  def terminate(reason, state) do
    Logger.debug("VM Died: #{inspect reason}")
    Farmbot.Logger.log("Sequence Finished with errors! #{inspect reason}", [:error_toast], ["Sequencer"])
    GenServer.stop(state.instruction_set, :normal)
    Farmbot.BotState.Monitor.remove_handler(__MODULE__)
  end
end
