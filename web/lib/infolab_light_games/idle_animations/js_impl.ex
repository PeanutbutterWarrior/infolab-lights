defmodule IdleAnimations.JSImpl do
  @behaviour IdleAnimations.IdleAnimation

  use GenServer, restart: :temporary
  require Logger

  @moduledoc "Idle animations that are written in js"

  @fps 20
  # about 10 minutes at 20fps
  @max_steps 12_000
  # 10 seconds at 20fps
  @no_frame_timeout @fps * 10

  defmodule State do
    use TypedStruct

    typedstruct enforce: true do
      field(:id, String.t())
      field(:file, Path.t())
      field(:name, String.t())

      field(:matrix, NativeMatrix.t())
      field(:process, Exile.Process.process() | nil, default: nil)
      field(:tmp_file, Path.t() | nil, default: nil)
      field(:working_input, iodata(), default: "")

      field(:fading_out, boolean(), default: false)
      field(:fader, Fader.t(), default: Fader.new(20))

      field(:steps, non_neg_integer(), default: 0)
      field(:steps_since_last_frame, non_neg_integer(), default: 0)
      field(:last_frame_time, non_neg_integer(), default: 0)

      field(:players, %{pid() => non_neg_integer()}, default: %{})
      field(:num_players, non_neg_integer(), default: 0)
    end
  end

  def start_link(options) do
    {screen_x, screen_y} = Screen.dims()

    mode = Keyword.fetch!(options, :mode)

    state = %State{
      id: Keyword.fetch!(options, :game_id),
      file: elem(mode, 0),
      name: elem(mode, 1),
      matrix: NativeMatrix.of_dims(screen_x, screen_y, Pixel.empty())
    }

    Logger.info("starting up js effect #{state.id}:#{inspect(state.file)}")

    GenServer.start_link(__MODULE__, state, options)
  end

  @impl true
  def possible_modes do
    Application.app_dir(:infolab_light_games, "priv")
    |> Path.join("js_effects/*.{js,ts}")
    |> Path.wildcard()
    |> Enum.map(&{&1, Path.basename(&1, Path.extname(&1))})
  end

  @impl true
  def init(%State{} = state) do
    Temp.track!()

    {:ok, state, {:continue, :start}}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    max_players = if state.name == "snake" do 1 else 0 end
    {:reply,
     %GameStatus{
       id: state.id,
       name: state.name,
       players: state.num_players,
       max_players: max_players,
       ready: true
     }, state}
  end

    @impl true
  def handle_call({:add_player, player}, _from, %State{} = state) do
    dbg(player)
    state = %State{state | num_players: state.num_players + 1, players: Map.put(state.players, player, state.num_players + 1)}
    cmd = Jason.encode!(%{msg: :addPlayer, player: state.num_players})
    Exile.Process.write(state.process, "#{cmd}\n")
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:remove_player, player}, _from, %State{} = state) do
    player_num = Map.get(state.players, player)
    if player_num do
      cmd = Jason.encode!(%{msg: :removePlayer, player: player_num})
      Exile.Process.write(state.process, "#{cmd}\n")
    end
    state = %State{state | num_players: state.num_players - 1, players: Map.delete(state.players, player)}
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:handle_input, player, input}, state) do
    player_num = Map.get(state.players, player)
    if player_num do
      cmd = Jason.encode!(%{msg: :handleInput, key: elem(input, 1), player: player_num})
      Exile.Process.write(state.process, "#{cmd}\n")
    end
    {:noreply, state}
  end

  @impl true
  def handle_cast(:start, state) do
    tick_request();
    {:noreply, state}
  end

  @impl true
  def handle_continue(:start, %State{file: src_file} = state) do
    deno = System.find_executable("deno")
    {tmp, path} = Temp.open!(%{suffix: ".ts", mode: [:utf8, :read, :write]})
    {screen_x, screen_y} = Screen.dims()

    src = File.read!(src_file)
    framework = File.read!(Application.app_dir(:infolab_light_games, ["priv", "running_framework.js"]))
    content = framework
              |> String.replace("/*{CodeHere}*/", src)
              |> String.replace("/*{ScreenWidth}*/", inspect(screen_x))
              |> String.replace("/*{ScreenHeight}*/", inspect(screen_y))

    IO.write(tmp, content)
    File.close(tmp)

    {:ok, s} = Exile.Process.start_link(~w(#{deno} run --allow-net -q #{path}))

    me = self()

    Task.start_link(fn ->
      Exile.Process.change_pipe_owner(s, :stdout, self())

      Stream.unfold(nil, fn _ ->
        try do
          case Exile.Process.read(s) do
            {:ok, data} ->
              send(me, {:data_from_js, data})
              {nil, nil}

            :eof ->
              Logger.info("JS sent EOF")
              GenServer.cast(me, :terminate)
              nil

            {:error, e} ->
              Logger.error("JS sent error: #{e}")
              GenServer.cast(me, :terminate)
              nil
          end
        catch
          _ -> nil
          :exit, _ -> nil
        end
      end)
      |> Stream.run()
    end)

    state = %State{state | process: s, tmp_file: path}

    {:noreply, state}
  end

  @impl true
  def handle_info(:tick, %State{} = state) do
    render(state)

    # don't have tons of in-flight frame requests
    time_since_last_frame = System.monotonic_time(:millisecond) - state.last_frame_time

    if state.steps_since_last_frame < 6 or time_since_last_frame > 500 do
      cmd = Jason.encode!(%{msg: :tick})
      Exile.Process.write(state.process, "#{cmd}\n")
    end

    state = %State{
      state
      | steps: state.steps + 1,
        fader: Fader.step(state.fader),
        steps_since_last_frame: state.steps_since_last_frame + 1
    }

    frame_timeout_reached = state.steps_since_last_frame > @no_frame_timeout

    if frame_timeout_reached or state.fading_out and Fader.done(state.fader) do
      {:stop, :normal, state}
    else
      if state.steps < @max_steps do
        tick_request()
        {:noreply, state}
      else
        {:noreply, start_fading_out(state)}
      end
    end
  end

  @impl true
  def handle_info({:data_from_js, msg}, %State{working_input: working_input} = state) do
    state = process_input([working_input, msg], state)

    {:noreply, state}
  end

  @impl true
  def handle_cast(:terminate, %State{} = state) do
    Logger.info("Beginning js effect termination")

    {:noreply, start_fading_out(state)}
  end

  defp fix_int(num) do
    max(min(trunc(num), 255), 0)
  end

  defp process_input(msg, %State{} = state) do
    {screen_x, screen_y} = Screen.dims()

    case Msgpax.unpack_slice(msg) do
      {:ok, parsed, rest} ->
        pixels =
          parsed
          |> Enum.map(fn %{"x" => x, "y" => y, "v" => [r, g, b]} ->
            {x, y, {fix_int(r), fix_int(g), fix_int(b)}}
          end)
          |> Enum.filter(fn {x, y, _} ->
            x >= 0 and x < screen_x and y >= 0 and y < screen_y
          end)

        state = %State{
          state
          | steps_since_last_frame: 0,
            last_frame_time: System.monotonic_time(:millisecond),
            matrix: NativeMatrix.set_from_list(state.matrix, pixels)
        }

        process_input(rest, state)

      {:error, _e} ->
        %State{state | working_input: msg}
    end
  end

  defp start_fading_out(%State{} = state) do
    tick_request()

    %State{state | fading_out: true, fader: %{state.fader | direction: :dec}}
  end

  defp tick_request do
    Process.send_after(self(), :tick, Integer.floor_div(1000, @fps))
  end

  defp render(%State{} = state) do
    frame = NativeMatrix.mul(state.matrix, Fader.percentage(state.fader))

    Screen.update_frame(frame)
  end
end
