defmodule Platser.Repo.Migrations.MigrateMembershipRolesAndParticipationSettings do
  use Ecto.Migration

  def up do
    alter table(:events) do
      add :allow_participant_comments, :boolean, default: false, null: false
      add :allow_participant_check_ins, :boolean, default: true, null: false
      add :allow_participant_live_location, :boolean, default: true, null: false
    end

    execute """
    UPDATE events
    SET allow_participant_comments = allow_public_comments
    """

    execute """
    UPDATE memberships
    SET role = CASE role
      WHEN 'admin' THEN 'full_manager'
      WHEN 'member' THEN 'participant'
      ELSE role
    END
    """
  end

  def down do
    execute """
    UPDATE memberships
    SET role = CASE role
      WHEN 'full_manager' THEN 'admin'
      WHEN 'content_manager' THEN 'member'
      WHEN 'participant' THEN 'member'
      ELSE role
    END
    """

    alter table(:events) do
      remove :allow_participant_live_location
      remove :allow_participant_check_ins
      remove :allow_participant_comments
    end
  end
end
