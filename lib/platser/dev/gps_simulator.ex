defmodule Platser.Dev.GpsSimulator do
  @moduledoc """
  Dev-only GenServer that drives simulated GPS movement.
  """

  use GenServer, restart: :permanent

  require Ash.Query

  alias Platser.Accounts.User
  alias Platser.Dev.GpsSimulator.Movement
  alias Platser.EventPresence
  alias Platser.Location

  @pubsub Platser.PubSub
  @topic "dev:simulator"
  @default_tick_ms 2_000

  @type pattern :: Movement.pattern()

  @type user_state :: %{
          user: User.t(),
          pattern: pattern(),
          pattern_state: Movement.pattern_state(),
          lat: float(),
          lng: float(),
          tracked?: boolean()
        }

  @type state :: %{
          event_id: String.t() | nil,
          users: [user_state()],
          tick_ref: reference() | nil,
          running?: boolean(),
          tick_ms: pos_integer()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec topic() :: String.t()
  def topic, do: @topic

  @spec get_state(GenServer.server()) :: state()
  def get_state(server \\ __MODULE__) do
    GenServer.call(server, :get_state)
  end

  @spec set_event(GenServer.server(), String.t()) :: :ok
  def set_event(server \\ __MODULE__, event_id) do
    GenServer.call(server, {:set_event, event_id})
  end

  @spec add_user(GenServer.server(), User.t(), pattern(), keyword()) :: :ok
  def add_user(server \\ __MODULE__, user, pattern, pattern_opts \\ []) do
    GenServer.call(server, {:add_user, user, pattern, pattern_opts})
  end

  @spec remove_user(GenServer.server(), String.t()) :: :ok
  def remove_user(server \\ __MODULE__, user_id) do
    GenServer.call(server, {:remove_user, user_id})
  end

  @spec start_simulation(GenServer.server()) :: :ok
  def start_simulation(server \\ __MODULE__) do
    GenServer.cast(server, :start_simulation)
  end

  @spec stop_simulation(GenServer.server()) :: :ok
  def stop_simulation(server \\ __MODULE__) do
    GenServer.cast(server, :stop_simulation)
  end

  @spec tick_now(GenServer.server()) :: :ok
  def tick_now(server \\ __MODULE__) do
    GenServer.call(server, :tick_now)
  end

  @impl true
  @spec init(keyword()) :: {:ok, state()}
  def init(opts) do
    tick_ms = Keyword.get(opts, :tick_ms, @default_tick_ms)
    event_id = Keyword.get(opts, :event_id) || dev_event_id()
    users = load_seeded_users() |> Enum.with_index() |> Enum.map(&seed_user_state/1)

    state = %{
      event_id: event_id,
      users: users,
      tick_ref: nil,
      running?: event_id != nil,
      tick_ms: tick_ms
    }

    {:ok, schedule_if_running(state)}
  end

  @impl true
  def handle_call(:get_state, _from, state), do: {:reply, state, state}

  def handle_call({:set_event, event_id}, _from, state) do
    {:reply, :ok, %{state | event_id: event_id}}
  end

  def handle_call({:add_user, user, pattern, pattern_opts}, _from, state) do
    user = normalize_user(user)

    if Enum.any?(state.users, &(&1.user.id == user.id)) do
      {:reply, :ok, state}
    else
      pattern_state =
        Movement.initial_state(pattern, default_pattern_opts(pattern, pattern_opts, user))

      {lat, lng} = Movement.current_position(pattern_state)

      user_state = %{
        user: user,
        pattern: pattern,
        pattern_state: pattern_state,
        lat: lat,
        lng: lng,
        tracked?: false
      }

      {:reply, :ok, %{state | users: [user_state | state.users]}}
    end
  end

  def handle_call({:remove_user, user_id}, _from, state) do
    {removed, remaining} = Enum.split_with(state.users, &(&1.user.id == user_id))

    Enum.each(removed, fn user_state ->
      if user_state.tracked? and state.event_id do
        EventPresence.untrack(self(), EventPresence.topic(state.event_id), user_state.user.id)
      end
    end)

    {:reply, :ok, %{state | users: remaining}}
  end

  def handle_call(:tick_now, _from, state) do
    {:reply, :ok, do_tick(state)}
  end

  @impl true
  def handle_cast(:start_simulation, %{running?: false} = state) do
    {:noreply, schedule_if_running(%{state | running?: true})}
  end

  def handle_cast(:start_simulation, state), do: {:noreply, state}

  def handle_cast(:stop_simulation, %{tick_ref: tick_ref} = state) do
    if tick_ref, do: Process.cancel_timer(tick_ref)
    {:noreply, %{state | running?: false, tick_ref: nil}}
  end

  @impl true
  def handle_info(:tick, state) do
    new_state = do_tick(state)

    next_state =
      if new_state.running? do
        schedule_if_running(%{new_state | running?: true})
      else
        %{new_state | tick_ref: nil}
      end

    {:noreply, next_state}
  end

  @impl true
  def handle_info({:simulator_tick, _users}, state), do: {:noreply, state}

  @spec do_tick(state()) :: state()
  defp do_tick(%{event_id: nil} = state) do
    broadcast({:simulator_tick, state.users})
    state
  end

  defp do_tick(state) do
    new_users =
      Enum.map(state.users, fn user_state ->
        {new_user_state, _} = advance_user(user_state, state.event_id)
        new_user_state
      end)

    broadcast({:simulator_tick, new_users})
    %{state | users: new_users}
  end

  @spec advance_user(user_state(), String.t()) :: {user_state(), term()}
  defp advance_user(%{user: user, tracked?: tracked?} = user_state, event_id) do
    {new_pos, new_pattern_state} =
      Movement.next_position(user_state.pattern, user_state.pattern_state)

    {lat, lng} = new_pos

    params = %{lat: lat, lng: lng, accuracy: nil, heading: nil}

    {:ok, _meta} = Location.update_presence(self(), event_id, user, params, tracked?)

    {
      %{user_state | lat: lat, lng: lng, pattern_state: new_pattern_state, tracked?: true},
      :ok
    }
  end

  @spec schedule_if_running(state()) :: state()
  defp schedule_if_running(%{running?: true, tick_ms: tick_ms} = state) do
    %{state | tick_ref: Process.send_after(self(), :tick, tick_ms)}
  end

  defp schedule_if_running(state), do: state

  @spec broadcast(term()) :: :ok | {:error, term()}
  defp broadcast(message), do: Phoenix.PubSub.broadcast(@pubsub, @topic, message)

  @spec load_seeded_users() :: [User.t()]
  defp load_seeded_users do
    User
    |> Ash.Query.filter(is_simulated == true)
    |> Ash.read!(authorize?: false)
  rescue
    _ -> []
  end

  @spec dev_event_id() :: String.t() | nil
  defp dev_event_id do
    case Platser.Events.Event
         |> Ash.Query.filter(name == "Dev Event")
         |> Ash.read_one(authorize?: false) do
      {:ok, %{id: id}} -> id
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @spec seed_user_state({User.t(), non_neg_integer()}) :: user_state()
  defp seed_user_state({user, index}) do
    pattern = Enum.at([:stationary, :linear, :random_walk, :route], rem(index, 4))
    pattern_state = Movement.initial_state(pattern, default_seed_opts(pattern, user, index))
    {lat, lng} = Movement.current_position(pattern_state)

    %{
      user: user,
      pattern: pattern,
      pattern_state: pattern_state,
      lat: lat,
      lng: lng,
      tracked?: false
    }
  end

  @spec normalize_user(User.t() | map()) :: User.t()
  defp normalize_user(%User{} = user), do: user

  defp normalize_user(user) do
    %User{
      id: Map.fetch!(user, :id),
      display_name: Map.fetch!(user, :display_name),
      email: Map.get(user, :email),
      is_simulated: Map.get(user, :is_simulated, true)
    }
  end

  @spec default_seed_opts(pattern(), User.t(), non_neg_integer()) :: keyword()
  defp default_seed_opts(:stationary, _user, index) do
    base = seed_base(index)
    [lat: base.lat, lng: base.lng]
  end

  defp default_seed_opts(:linear, _user, index) do
    base = seed_base(index)

    [
      start_lat: base.lat,
      start_lng: base.lng,
      end_lat: base.lat + 0.01,
      end_lng: base.lng + 0.01,
      total_steps: 20
    ]
  end

  defp default_seed_opts(:random_walk, _user, index) do
    base = seed_base(index)
    [lat: base.lat, lng: base.lng, step_size: 0.0015]
  end

  defp default_seed_opts(:route, _user, index) do
    base = seed_base(index)
    [lat: base.lat, lng: base.lng, radius: 0.002]
  end

  @spec default_pattern_opts(pattern(), keyword(), User.t()) :: keyword()
  defp default_pattern_opts(pattern, pattern_opts, user) do
    Keyword.merge(default_seed_opts(pattern, user, 0), pattern_opts)
  end

  @spec seed_base(non_neg_integer()) :: %{lat: float(), lng: float()}
  defp seed_base(index) do
    %{lat: 59.3293 + index * 0.002, lng: 18.0686 + index * 0.002}
  end
end
