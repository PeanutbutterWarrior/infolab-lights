defmodule Coordinator do
  use GenServer, restart: :transient
  require Logger

  @type via_tuple :: {:via, atom(), {atom(), String.t()}}
  @type activity_id :: binary()

  defmodule State do
    use TypedStruct

    typedstruct enforce: true do
      field(:queue, :queue.queue(Coordinator.QueuedActivity))
      field(:current_activity, String.t() | none())
      field(:timer, reference() | none())
      field(:enforce_timer, boolean())
    end
  end

  defmodule QueuedActivity do
    use TypedStruct

    typedstruct enforce: true do
      field(:id, String.t())
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
        queue: :queue.new(),
        current_activity: nil,
        timer: nil,
        enforce_timer: false,
      },
      name: __MODULE__
    )
  end

  @impl true
  def init(state) do
    # Stop any activities from a crashed coordinator
    activities = DynamicSupervisor.which_children(GameManager)
    activities
    |> Enum.map(&elem(&1, 1)) # Get pids
    |> Enum.map(&GenServer.stop/1) # Stop them

    {:ok, state, {:continue, :check_current_activity}}
  end

  @impl true
  def handle_cast({:terminate_activity, id}, %State{} = state) do
    {:noreply, state, {:continue, {:terminate_activity, id}}}
  end

  @impl true
  def handle_cast({:route_input, player, input}, state) do
    if state.current_activity do
      GenServer.cast(via_tuple(state.current_activity), {:handle_input, player, input})
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:terminate_activity, id}, %State{} = state) do
    {:noreply, state, {:continue, {:terminate_activity, id}}}
  end

  @impl true
  def handle_continue({:terminate_activity, activity_id}, %State{} = state) do
    try_stop(activity_id)
    state =
    cond do
      state.current_activity == activity_id ->
        # Current activity is the one to be terminated
        Process.cancel_timer(state.timer)
        %State{state | current_activity: nil, timer: nil}


      :queue.any(fn %QueuedActivity{id: id} -> id == activity_id end, state.queue) ->
        # Queue contains activity to be terminated
        queue = :queue.delete_with(fn %QueuedActivity{id: id} -> id == activity_id end, state.queue)
        %State{state | queue: queue}


      true ->
        # No activity has that id
        state
    end
    Phoenix.PubSub.broadcast!(
      InfolabLightGames.PubSub,
      "coordinator:status",
      {:activity_terminated, activity_id}
    )

    {:noreply, state, {:continue, :start_activity}}
  end

  @impl true
  def handle_continue(:start_activity, %State{} = state) do
    state = if !state.current_activity do
      {id, queue, max_time, enforce_timer} = case :queue.out(state.queue) do
        {{:value, %QueuedActivity{id: id}}, q} ->
          Logger.info("Promoting activity #{id} from the queue")
          {id, q, @queued_max_time, true}
        {:empty, q} ->
          Logger.info("Starting new random activity")
          {module, mode} = get_random_activity()
          {start_new_activity(module, mode), q, @random_max_time, false}
      end
      GenServer.cast(via_tuple(id), :start)
      timer = Process.send_after(self(), {:terminate_activity, id}, max_time)
      %State{
        queue: queue,
        current_activity: id,
        timer: timer,
        enforce_timer: enforce_timer
      }
    else
      state
    end
    push_status(state)
    {:noreply, state}
  end

  @impl true
  def handle_continue(:check_current_activity, %State{} = state) do
    cond do
      !state.current_activity ->
        {:noreply, state, {:continue, :start_activity}}
      :queue.len(state.queue) > 0 && !state.enforce_timer ->
        {:noreply, state, {:continue, {:terminate_activity, state.current_activity}}}
      true ->
        push_status(state)
        {:noreply, state}
    end
  end

  @impl true
  def handle_call({:join_game, id, player}, _from, state) do
    try do
      :ok = GenServer.call(via_tuple(id), {:add_player, player})
    catch
      :exit, e -> Logger.warning("Couldn't join_game: #{inspect(e)}")
    else
      _ -> Phoenix.PubSub.broadcast!(InfolabLightGames.PubSub, "player:status", {:player_join_game, id, player})
    end

    {:reply, id, state, {:continue, :check_current_activity}}
  end

  @impl true
  def handle_call({:leave_game, id, player}, _from, state) do
    try do
      :ok = GenServer.call(via_tuple(id), {:remove_player, player})
    catch
      :exit, e -> Logger.warning("Couldn't leave_game: #{inspect(e)}")
    else
      _ -> Phoenix.PubSub.broadcast!(InfolabLightGames.PubSub, "player:status", {:player_leave_game, id, player})
    end

    {:reply, id, state, {:continue, :check_current_activity}}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    {:reply, get_status(state), state}
  end

  @impl true
  def handle_call({:queue_activity, module, mode, player}, _from, %State{} = state) do
    Logger.info("Queueing activity #{module}:#{inspect(mode)}")
    id = start_new_activity(module, mode)
    if player do
      GenServer.call(via_tuple(id), {:add_player, player})
    end
    queue = :queue.in(%QueuedActivity{id: id}, state.queue)
    state = %State{state | queue: queue}

    {:reply, {:ok, id}, state, {:continue, :check_current_activity}}
  end

  defp modes_for_modules(modules) do
    modules
    |> Enum.flat_map(fn mod -> Enum.map(apply(mod, :possible_modes, []), &{mod, &1})
    end)
  end

  defp start_new_activity(module, mode) do
    Logger.info("Starting activity #{module}:#{inspect(mode)}")
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

    id
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
      GenServer.call(via_tuple(state.current_activity), :get_status)
    else
      nil
    end

    queue = :queue.filtermap(fn %QueuedActivity{id: id} -> {true, GenServer.call(via_tuple(id), :get_status)} end, state.queue) |> :queue.to_list()

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

  defp try_stop(id) do
    if GenServer.whereis(via_tuple(id)) do
      GenServer.stop(via_tuple(id))
    end
  end

  defp get_random_activity() do
    modes_for_modules([IdleAnimations.Ant, IdleAnimations.GOL, IdleAnimations.JSImpl]) |> Enum.random
  end

  def terminate_activity(id) do
    Logger.info("Terminating current activity")
    GenServer.cast(__MODULE__, {:terminate_activity, id})
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
