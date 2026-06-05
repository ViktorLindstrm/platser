# ADR-0024: Member Management — Remove and Role Updates

## Status
Accepted

## Context
Event admins need the ability to manage members on the event dashboard by:
1. Removing members from an event
2. Promoting members to admin or demoting admins to member

These capabilities are essential for real-world event management, where hosts may want to revoke access or elevate contributors to co-organizers.

## Decision

### Actions

#### `Membership.remove` (destroy action)
- **Authorization**: Only admins of the event may remove members
  - Policy: `authorize_if expr(exists(event.memberships, user_id == ^actor(:id) and role == :admin))`
- **Validation**: Last admin cannot be removed (see "Last Admin Guard" below)
- **Effect**: Deletes the membership record; the user loses access to the event map
- **Code interface**: `Events.remove_member(membership, actor: actor)`

#### `Membership.update_role` (update action)
- **Attributes**: Accepts `:role` only (`[:member, :admin]`)
- **Authorization**: Only admins may update member roles
  - Policy: `authorize_if expr(exists(event.memberships, user_id == ^actor(:id) and role == :admin))`
- **Validation**: Last admin cannot be demoted (see "Last Admin Guard" below)
- **Effect**: Updates the membership's role
- **Code interface**: `Events.update_member_role(membership, %{role: :admin}, actor: actor)`

### Last Admin Guard

To prevent orphaning an event (where no admin remains), the `Platser.Events.Changes.GuardLastAdmin` change validates both actions:

- **Count check**: Before removal/demotion, count admins in the event
- **Validation rule**: If `admin_count <= 1 AND membership.role == :admin`:
  - For `:remove`: Add error "Cannot remove the last admin from an event."
  - For `:update_role` to `:member`: Add error "Cannot demote the last admin from an event."
- **Implementation**: Uses `Ash.Query.filter/2` with `authorize?: false` to count admins across authorization boundaries

### Dashboard UI

The member list in `DashboardLive` shows management controls on hover (visible to admins only):

- **Role toggle button**: 
  - If member is admin: "Demote to Member" button (downward arrow icon)
  - If member is regular: "Promote to Admin" button (upward arrow icon)
- **Remove button**: Red X icon with "Remove Member" title
- **Confirmation**: Both actions use `data-confirm` attribute for inline confirmation
- **Update**: Member list uses LiveView streams; updates/deletes are reflected immediately

### Error Handling

Both actions return `Ash.Error.Invalid` on validation failure. The `DashboardLive` handler extracts error messages and displays them in the flash:

```elixir
{:error, %Ash.Error.Invalid{} = err} ->
  message = format_error(err)
  {:noreply, put_flash(socket, :error, message)}
```

## Consequences

- **Positive**:
  - Admins can revoke member access instantly (no delay)
  - Prevents accidental orphaning of events
  - Simple, declarative authorization at the resource level
  - Member list remains synchronized in real-time via stream updates
  
- **Negative**:
  - Admin cannot transfer sole ownership (must add another admin first)
  - No audit trail of who removed/promoted whom (future enhancement: Activity.Entry logging)
  - No soft delete; removed members lose all history tied to their membership

## Future Enhancements

1. **Activity logging**: Create `Activity.Entry` records when members are removed or promoted
2. **Soft delete**: Keep removed memberships but mark them as inactive (e.g., `removed_at` timestamp)
3. **Role hierarchy**: Support owner-only actions (e.g., delete event)
4. **Bulk operations**: Remove/promote multiple members at once
