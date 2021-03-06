defmodule Command do
  require Logger
  @log_tag "BotControl"
  @type command_output :: :done | :timeout | :error
  @moduledoc """
    BotCommands.
  """

  @doc """
    EMERGENCY STOP.
    This will happen in a pretty specific order.
    first: write an "E" to the serial line directly.
    second: stop any running sequences.
    third: Probably write another E.
    fourth: pause running regimens and other stuff that might do serial stuff
            on a timer.
  """
  @spec e_stop :: {:error, atom} | :ok
  def e_stop do
    # The index of the lock "e_stop". should be an integer or nil
    e_stop(Farmbot.BotState.get_lock("e_stop"))
  end

  @spec e_stop(integer) :: {:error, :already_locked}
  def e_stop(integer) when is_integer(integer), do: {:error, :already_locked}

  @spec e_stop(nil) :: :ok
  def e_stop(nil) do
    Farmbot.BotState.add_lock("e_stop")
    Farmbot.Logger.log("E STOPPING!", [:error_toast, :error_ticker], [@log_tag])
    Farmbot.Serial.Handler.e_stop
    Farmbot.Scheduler.e_stop_lock
    :ok
  end

  @doc """
    resume from an e stop
    This is way to complex
  """
  @spec resume() :: :ok | {:error, atom}
  def resume do
    # The index of the lock "e_stop". should be an integer or nil
    resume(Farmbot.BotState.get_lock("e_stop"))
  end

  @spec resume(integer | nil) :: :ok | {:error, atom}
  def resume(integer) when is_integer(integer) do
    Farmbot.Serial.Handler.resume
    params = Farmbot.BotState.get_all_mcu_params
    # The firmware takes forever to become ready again.
    Process.sleep(2000)
    case Enum.partition(params, fn({param, value}) ->
      param_int = Farmbot.Serial.Gcode.Parser.parse_param(param)
      Command.update_param(param_int, value)
    end)
    do
      {_, []} ->
        Farmbot.Logger.log("Bot Back Up and Running!", [:ticker], [@log_tag])
        Farmbot.BotState.remove_lock("e_stop")
        Farmbot.Scheduler.e_stop_unlock
        :ok
      {_, failed} ->
        Logger.error("Param setting failed! #{inspect failed}")
        {:error, :prams}
    end
  end

  def resume(nil) do
    {:error, :not_locked}
  end

  @doc """
    Home All
  """
  @spec home_all(number | nil) :: command_output
  def home_all(speed \\ nil) do
    msg = "HOME ALL"
    Logger.debug(msg)
    Farmbot.Logger.log(msg, [], [@log_tag])
    Command.move_absolute(0, 0, 0, speed || Farmbot.BotState.get_config(:steps_per_mm))
  end

  @doc """
    Home x
  """
  @spec home_x() :: command_output
  def home_x() do
    msg = "HOME X"
    Logger.debug(msg)
    Farmbot.Logger.log(msg, [], [@log_tag])
    Farmbot.Serial.Gcode.Handler.block_send("F11")
  end

  @doc """
    Home y
  """
  @spec home_y() :: command_output
  def home_y() do
    msg = "HOME Y"
    Logger.debug(msg)
    Farmbot.Logger.log(msg, [], [@log_tag])
    Farmbot.Serial.Gcode.Handler.block_send("F12")
  end

  @doc """
    Home z
  """
  @spec home_z() :: command_output
  def home_z() do
    msg = "HOME Z"
    Logger.debug(msg)
    Farmbot.Logger.log(msg, [], [@log_tag])
    Farmbot.Serial.Gcode.Handler.block_send("F13")
  end

  @doc """
    Calibrates an axis. May be used for other calibration things later.
  """
  @spec calibrate(String.t) :: command_output
  def calibrate("x") do
    Farmbot.Serial.Gcode.Handler.block_send("F14")
    |> logmsg("X Axis Calibration")
  end

  def calibrate("y") do
    Farmbot.Serial.Gcode.Handler.block_send("F15")
    |> logmsg("Y Axis Calibration")
  end

  def calibrate("z") do
    Farmbot.Serial.Gcode.Handler.block_send("F16")
    |> logmsg("Z Axis Calibration")
  end

  @doc """
    Writes a pin high or low
  """
  @spec write_pin(number, number, number) :: command_output
  def write_pin(pin, value, mode)
  when is_integer(pin) and is_integer(value) and is_integer(mode) do
    Farmbot.BotState.set_pin_mode(pin, mode)
    Farmbot.BotState.set_pin_value(pin, value)
    Farmbot.Serial.Gcode.Handler.block_send("F41 P#{pin} V#{value} M#{mode}")
    |> logmsg("Pin Write")
  end

  @doc """
    Moves to (x,y,z) point.
  """
  @spec move_absolute(number, number, number, number | nil) :: command_output
  def move_absolute(x ,y ,z ,s \\ nil)
  def move_absolute(x, y, z, s) do
    msg = "Moving to X#{x} Y#{y} Z#{z}"
    Logger.debug(msg)
    Farmbot.Logger.log(msg, [], [@log_tag])
    Farmbot.Serial.Gcode.Handler.block_send(
    "G00 X#{x} Y#{y} Z#{z} S#{s || Farmbot.BotState.get_config(:steps_per_mm)}")
    |> logmsg("Movement")
  end

  @doc """
    Gets the current position
    then pipes into move_absolute
    * {:x, `speed`, `amount`}
    * {:y, `speed`, `amount`}
    * {:z, `speed`, `amount`}
    * %{x: `amount`, y: `amount`, z: `amount` ,s: `speed`}
  """
  @spec move_relative(
  {:x, number | nil, number} |
  {:y, number | nil, number} |
  {:z, number | nil, number} |
  %{x: number, y: number, z: number, speed: number | nil}) :: command_output
  def move_relative({:x, s, move_by}) when is_integer move_by do
    [x,y,z] = Farmbot.BotState.get_current_pos
    move_absolute(x + move_by,y,z,s)
  end

  def move_relative({:y, s, move_by}) when is_integer move_by do
    [x,y,z] = Farmbot.BotState.get_current_pos
    move_absolute(x,y + move_by,z,s)
  end

  def move_relative({:z, s, move_by}) when is_integer move_by do
    [x,y,z] = Farmbot.BotState.get_current_pos
    move_absolute(x,y,z + move_by,s)
  end

  # This is a funky one. Only used in sequences right now.
  def move_relative(%{x: x_move_by, y: y_move_by, z: z_move_by, speed: speed})
  when is_integer(x_move_by) and
       is_integer(y_move_by) and
       is_integer(z_move_by)
  do
    [x,y,z] = Farmbot.BotState.get_current_pos
    move_absolute(x + x_move_by,y + y_move_by,z + z_move_by, speed)
  end

  @doc """
    Used when bootstrapping the bot.
    Reads all the params.
    TODO: Make these not magic numbers.
  """
  @spec read_all_params(list(number)) :: :ok | :fail
  def read_all_params(params \\ [0,11,12,13,21,22,23,
                                 31,32,33,41,42,43,51,
                                 52,53,61,62,63,71,72,73, 101,102,103])
  when is_list(params) do
    case Enum.partition(params, fn param ->
      GenServer.cast(Farmbot.Serial.Gcode.Handler, {:send, "F21 P#{param}", self()})
      :done == Farmbot.Serial.Gcode.Handler.block(2500)
    end) do
      {_, []} -> :ok
      {_, failed_params} -> read_all_params(failed_params)
    end
  end

  @doc """
    Reads a pin value.
    mode can be 0 (digital) or 1 (analog)
  """
  @spec read_pin(number, 0 | 1) :: command_output
  def read_pin(pin, mode \\ 0) when is_integer(pin) do
    Farmbot.BotState.set_pin_mode(pin, mode)
    Farmbot.Serial.Gcode.Handler.block_send("F42 P#{pin} M#{mode}")
    |> logmsg("read_pin")
  end

  @doc """
    gets the current value, and then toggles it.
  """
  @spec toggle_pin(number) :: command_output
  def toggle_pin(pin) when is_integer(pin) do
    pinMap = Farmbot.BotState.get_pin(pin)
    case pinMap do
      %{mode: 0, value: 1 } ->
        write_pin(pin, 0, 0)
      %{mode: 0, value: 0 } ->
        write_pin(pin, 1, 0)
      nil ->
        read_pin(pin, 0)
        toggle_pin(pin)
      _ -> :fail
    end
  end

  @doc """
    Reads a param. Needs the integer version of said param.
  """
  @spec read_param(number) :: command_output
  def read_param(param) when is_integer param do
    case Farmbot.Serial.Gcode.Handler.block_send "F21 P#{param}" do
      :timeout ->
        Process.sleep(100)
        read_param(param)
      whatever -> whatever
    end
  end

  @doc """
    Update a param. Param needs to be an integer.
  """
  @spec update_param(number | nil, number) :: command_output
  def update_param(param, value) when is_integer param do
    case Farmbot.Serial.Gcode.Handler.block_send "F22 P#{param} V#{value}" do
      :timeout ->
        Process.sleep(10)
        update_param(param, value)
      _ ->
      Process.sleep(100)
      Command.read_param(param)
    end
  end

  def update_param(nil, _value) do
    {:error, "Unknown param"}
  end

  @spec logmsg(command_output, String.t) :: command_output
  defp logmsg(:done, command) when is_bitstring(command) do
    Farmbot.Logger.log("#{command} Complete", [],[@log_tag])
    :done
  end

  defp logmsg(other, command) when is_bitstring(command) do
    Logger.error("#{command} Failed")
    Farmbot.Logger.log("#{command} Failed", [:error_toast, :error_ticker],[@log_tag])
    other
  end
end
