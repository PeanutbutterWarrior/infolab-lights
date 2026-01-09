defmodule InfolabLightGamesWeb.PageLive do
  use InfolabLightGamesWeb, :live_view
  require Logger

  @impl true
  def mount(_params, %{"remote_ip" => remote_ip} = _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(InfolabLightGames.PubSub, "coordinator:status")
      Phoenix.PubSub.subscribe(InfolabLightGames.PubSub, "bans")
    end

    {width, height} = Screen.dims()
    coordinator_status = Coordinator.status()

    socket =
      socket
      |> assign(queued_activity_id: nil, joined_games: %{})
      #|> assign(game_id: nil)
      |> assign(width: width, height: height)
      |> assign(coordinator_status: coordinator_status)
      |> assign(remote_ip: remote_ip)
      |> assign(banned: Bans.is_banned?(remote_ip))
      |> assign(animation_names: Coordinator.possible_idle_animations())
      |> assign(:scripts, [
        Routes.static_path(socket, "/assets/app.js")
      ])

    Logger.info("mounted #{inspect(self())}/#{inspect(remote_ip)} on main page")
    {:ok, _} = Presence.track_user(self(), remote_ip)

    {:ok, socket}
  end

  @impl true
  def handle_info({:banned, banned_ip}, %{assigns: %{joined_games: joined_games, remote_ip: remote_ip}} = socket) do
    socket = if banned_ip == remote_ip do
      Enum.reduce(joined_games, socket, &leave_game(&2, &1))
      |> assign(banned: true)
      |> assign(joined_games: [])
    else
      socket
    end
    {:noreply, socket}
  end

  @impl true
  def handle_info({:coordinator_update, status}, socket) do
    {:noreply, assign(socket, coordinator_status: status)}
  end

  @impl true
  def handle_info({:game_win, id, winner}, socket) do
    {:noreply, put_flash(socket, :info, "Player '#{winner}' won the game: #{id}")}
  end

  @impl true
  def handle_info({:activity_terminated, id}, %{assigns: %{joined_games: joined_games, queued_activity_id: queued_id, remote_ip: remote_ip}} = socket) do
    # Clear queued activity if it's terminated
    socket = if queued_id == id do
      {:ok, _} = Presence.update_user_status(self(), remote_ip, "idle")
      assign(socket, queued_activity_id: nil)
    else
      socket
    end
    socket = if !is_nil(joined_games[id]) do
      assign(socket, joined_games: %{joined_games | id => nil})
    else
      socket
    end

    {:noreply, socket}
  end

  def handle_event("queue-activity", _params, %{assigns: %{banned: true}} = socket) do
    {:noreply, put_flash(socket, :error, "Error: User banned")}
  end

  def handle_event("queue-activity", %{"activity-name" => activity_name}, %{assigns: %{queued_activity_id: nil}} = socket) do
    Logger.info("Queueing #{activity_name}")
    {module, mode} = case activity_name do
      "pong-ex-game" -> {Games.Pong, nil}
      "snake-ex-game" -> {Games.Snake, nil}
      _ -> Coordinator.idle_animation_for_name(activity_name)
    end

    {:ok, id} = Coordinator.queue_activity(module, mode, self())

    socket =
      socket
      |> assign(queued_activity_id: id)
      |> put_flash(:info, "Queued #{activity_name}")

    {:noreply, socket}
  end

  def handle_event("queue-activity", _params, socket) do
    {:noreply, put_flash(socket, :error, "You've already queued an activity")}
  end

  @impl true
  def handle_event("join", _params, %{assigns: %{banned: true}} = socket) do
    {:noreply, put_flash(socket, :error, "Error: User banned")}
  end

  @impl true
  def handle_event(
        "join",
        %{"game-id" => id},
        %{assigns: %{joined_games: joined_games, remote_ip: remote_ip}} = socket
      ) do
    Coordinator.join_game(id, self())

    {:ok, _} = Presence.update_user_status(self(), remote_ip, "in game #{id}")

    socket =
      socket
      |> assign(joined_games: %{joined_games | id => true})
      |> put_flash(:info, "Joined game: #{id}")

    {:noreply, socket}
  end

  @impl true
  def handle_event(
        "leave",
        %{"game-id" => id},
        %{assigns: %{joined_games: joined_games}} = socket
      ) do
    socket = if joined_games[id] do
      leave_game(socket, id)
    else
      socket
    end
    {:noreply, socket}
  end

  @impl true
  def handle_event("key_up", %{"key" => key}, socket) do
    Coordinator.route_input(self(), {false, key})

    {:noreply, socket}
  end

  @impl true
  def handle_event("key_down", %{"key" => key}, socket) do
    Coordinator.route_input(self(), {true, key})

    {:noreply, socket}
  end

  @impl true
  def terminate(_reason, %{assigns: %{joined_games: joined_games}} = socket) do
    Logger.warning("Terminating user")
    :ok = Presence.untrack_user(self(), socket.assigns.remote_ip)

    Enum.map(Map.keys(joined_games), &Coordinator.leave_game(&1, self()))
  end

  defp leave_game(socket, id) do
    Coordinator.leave_game(id, self())

    {:ok, _} = Presence.update_user_status(self(), socket.assigns.remote_ip, "idle")

    socket =
      socket
      |> assign(joined_games: %{socket.assigns.joined_games | id => nil})
      |> put_flash(:info, "Left game: #{id}")

    socket
  end
end
