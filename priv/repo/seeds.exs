# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# This script is idempotent: re-running it will skip records that already exist.

require Ash.Query

admin_email = "admin@dev.local"

admin =
  case Platser.Accounts.User
       |> Ash.Query.filter(email == ^admin_email)
       |> Ash.read_one(authorize?: false) do
    {:ok, nil} ->
      IO.puts("Creating dev admin user...")

      Platser.Accounts.User
      |> Ash.Changeset.for_create(:register, %{
        email: admin_email,
        display_name: "Dev Admin",
        password: "devpassword",
        password_confirmation: "devpassword"
      })
      |> Ash.Changeset.set_context(%{strategy_name: :password})
      |> Ash.create!(authorize?: false)

    {:ok, existing} ->
      IO.puts("Dev admin user already exists, skipping.")
      existing
  end

event_name = "Dev Event"

event =
  case Platser.Events.Event
       |> Ash.Query.filter(name == ^event_name and creator_id == ^admin.id)
       |> Ash.read_one(authorize?: false) do
    {:ok, nil} ->
      IO.puts("Creating dev event...")
      now = DateTime.utc_now()

      Platser.Events.Event
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: event_name,
          description: "Auto-generated dev event for local development",
          starts_at: now,
          ends_at: DateTime.add(now, 7 * 24 * 3600, :second)
        },
        actor: admin
      )
      |> Ash.create!()

    {:ok, existing} ->
      IO.puts("Dev event already exists, skipping.")
      existing
  end

IO.puts("""
Seeds complete!
  Admin email:    #{admin.email}
  Admin password: devpassword
  Event name:     #{event.name}
  Join code:      #{event.join_code}
  Map URL:        /events/#{event.id}/map
""")
