defmodule Coordinator do
  use GenServer, restart: :transient
  require Logger

  @type via_tuple() :: {:via, atom(), {atom(), String.t()}}

  defmodule State do
    use TypedStruct

    typedstruct enforce: true do
      field(:queue, Qex.t({module(), any(), binary()}))
      field(:current_activity, Coodinator.via_tuple() | none())
      field(:timer, reference() | none())
      field(:enforce_timer, boolean())
    end
  end

  # Maximum duration for a queued activity
  @queued_max_time 60 * 10 * 1000
  # Maximum duration for a randomly picked activity
  @random_max_time 60 * 5 * 1000

  def start_link(_opts) do
    GenServer.start_link(
      __MODULE__,
      %State{
        queue: Qex.new(),
        current_activity: nil,
        timer: nil,
        enforce_timer: false,
      },
      name: __MODULE__
    )
  end

  @impl true
  def init(state) do
    {:ok, state, {:continue, :tick}}
  end

  @impl true
  def handle_cast(:terminate_activity, %State{} = state) do
    state = terminate(state)
    {:noreply, state, {:continue, :tick}}
  end

  @impl true
  def handle_info(:terminate_activity, %State{} = state) do
    state = terminate(state)
    {:noreply, state, {:continue, :tick}}
  end

  defp terminate(%State{} = state) do
    if !is_nil(state.current_activity) do
      id = state.current_activity
      try_stop(id)

      Phoenix.PubSub.broadcast!(
        InfolabLightGames.PubSub,
        "coordinator:status",
        {:activity_terminated, id}
      )
    end
    state = %State{state | current_activity: nil}
    push_status(state)
    state
  end

  @impl true
  def handle_cast({:route_input, player, input}, state) do
    if state.current_activity do
      GenServer.cast(state.current_activity, {:handle_input, player, input})
    end

    {:noreply, state}
  end

  # TODO
  @impl true
  def handle_call({:join_game, id, player}, _from, state) do
    try do
      :ok = GenServer.call(via_tuple(id), {:add_player, player})
    catch
      :exit, e -> Logger.warning("Couldn't join_game: #{inspect(e)}")
    end

    {:reply, id, state, {:continue, :tick}}
  end

  # TODO
  @impl true
  def handle_call({:leave_game, id, player}, _from, state) do
    try do
      :ok = GenServer.call(via_tuple(id), {:remove_player, player})
    catch
      :exit, e -> Logger.warning("Couldn't leave_game: #{inspect(e)}")
    end

    {:reply, id, state, {:continue, :tick}}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    {:reply, get_status(state), state}
  end

  @impl true
  def handle_call({:queue_activity, module, mode, player}, _from, state) do
    state = update_in(state.queue, &Qex.push(&1, {module, mode, player}))
    {:reply, :ok, state, {:continue, :tick}}
  end

  @impl true
  def handle_continue(:tick, %State{} = state) do
    # If timer shouldn't be enforced (random activity, not queued) and theres a queued activity, start it
    state =
    if is_nil(state.current_activity) || (Enum.count(state.queue) > 0 && !state.enforce_timer)  do
      if state.timer do
        Process.cancel_timer(state.timer)
      end
      {new_state, _pid} = start_new_activity(state)
      new_state
    else
      state
    end
    push_status(state)
    {:noreply, state}
  end

  defp modes_for_modules(modules) do
    modules
    |> Enum.flat_map(fn mod -> Enum.map(apply(mod, :possible_modes, []), &{mod, &1})
    end)
  end

  defp start_new_activity(state) do
    # Get the first item in the queue or else pick a random activity
    {new_game, queue, maximum_duration, enforce_timer} = case Qex.pop(state.queue) do
        {{:value, ng}, q} -> {ng, q, @queued_max_time, true}
        {:empty, q} -> {get_random_activity(), q, @random_max_time, false}
    end
    {module, mode, initial_player} = new_game

    Logger.info("Starting activity #{module}:#{inspect(mode)}")

    # Stop the current activity if it exists
    if state.current_activity do
      # We need to stop the activity immediately to stop it drawing over the new one
      try_stop(state.current_activity)
    end

    id = random_id()

    {:ok, pid} = DynamicSupervisor.start_child(
      GameManager,
      {module, game_id: id, name: via_tuple(id), mode: mode}
    )

    Task.start_link(fn ->
      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} ->
          GenServer.cast(__MODULE__, {:terminate_activity, id})
      end
    end)

    if initial_player do
      GenServer.call(pid, {:add_player, initial_player})
    end

    timer = Process.send_after(self(), :terminate_activity, maximum_duration)

    state = %State {
      queue: queue,
      current_activity: via_tuple(id),
      timer: timer,
      enforce_timer: enforce_timer,
    }

    {state, pid}
  end

  defp push_status(%State{} = state) do
    Phoenix.PubSub.broadcast!(
      InfolabLightGames.PubSub,
      "coordinator:status",
      {:coordinator_update, get_status(state)}
    )
  end

  defp get_status(%State{} = state) do
    current = if !is_nil(state.current_activity) do
      GenServer.call(state.current_activity, :get_status)
    else
      nil
    end

    queue = Enum.map(state.queue, &GenServer.call(&1, :get_status))

    %CoordinatorStatus{
      current_activity: current,
      queue: queue
    }
  end

  defp random_id() do
    ?a..?z
    |> Enum.take_random(6)
    |> List.to_string()
  end

  defp via_tuple(id) do
    {:via, Registry, {GameRegistry, id}}
  end

  defp try_stop(pid) do
    if GenServer.whereis(pid) do
      GenServer.stop(pid)
    end
  end

  defp get_random_activity() do
    # Chosen by random dice roll
    {IdleAnimations.Ant, :original, nil}
  end

  def terminate_activity() do
    Logger.info("Terminating current activity")
    GenServer.cast(__MODULE__, :terminate_activity)
  end

  def route_input(player, input) do
    GenServer.cast(__MODULE__, {:route_input, player, input})
  end

  def queue_activity(module, mode, initial_player) do
    GenServer.call(__MODULE__, {:queue_activity, module, mode, initial_player})
  end

  def join_game(id, player) do
    Logger.info("#{inspect(player)} joining game #{id}")
    GenServer.call(__MODULE__, {:join_game, id, player})
  end

  def leave_game(id, player) do
    Logger.info("#{inspect(player)} leaving game #{id}")
    GenServer.call(__MODULE__, {:leave_game, id, player})
  end

  def status do
    GenServer.call(__MODULE__, :get_status)
  end

  def possible_idle_animations do
    modes_for_modules([IdleAnimations.Ant, IdleAnimations.GOL, IdleAnimations.JSImpl])
    |> Enum.map(fn {_, {_, name}} -> name end)
  end

  def idle_animation_for_name(name) do
    modes_for_modules([IdleAnimations.Ant, IdleAnimations.GOL, IdleAnimations.JSImpl])
    |> Enum.find(fn {_, {_, n}} -> name == n end)
  end
end
