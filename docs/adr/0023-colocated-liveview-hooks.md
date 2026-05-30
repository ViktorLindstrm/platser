# ADR-0023: Colocated LiveView Hooks for Client-Side Interop

## Status
Accepted

## Context
Phoenix v1.8 introduces colocated hooks (`:type={Phoenix.LiveView.ColocatedHook}`) that allow
developers to define JavaScript hooks directly within HEEx templates without inline `<script>` tags.
This approach integrates cleanly with the framework's LiveView compilation and avoids the old
pitfalls of inline scripts breaking LiveView hot-reload and event handling.

The copy invite link feature on the dashboard is the first use case where client-side clipboard
access is needed to improve the user experience. Rather than forcing users to manually copy the
invite code and construct a URL, a single-click button can copy the full invite URL
(`/join/{code}`) to the clipboard with visual feedback.

## Decision
Use colocated hooks for client-side JavaScript interactions, with the following pattern:

1. **Hook naming:** Use dot-prefixed names (e.g., `.CopyInviteLink`) to distinguish colocated hooks
   from external hooks defined in `assets/js/`.
2. **Placement:** Define the hook immediately before the closing `</Layouts.app>` tag or at the end
   of the template where it's used, with a comment section divider for clarity.
3. **State management:** Pass data to the hook via `data-*` HTML attributes; use `this.el.dataset`
   to access in the hook.
4. **Visual feedback:** For user actions (e.g., button clicks), provide immediate visual feedback
   (e.g., temporary icon/color change) to confirm the action was successful.
5. **Error handling:** Log errors to the browser console and fail gracefully without breaking
   the page or showing console errors to users.

## Example: Copy Invite Link
```html
<button
  id="copy-invite-link-btn"
  phx-hook=".CopyInviteLink"
  data-join-code={@event.join_code}
  class="p-3 rounded-xl bg-primary text-primary-content border border-primary
         hover:brightness-110 transition-all active:scale-95 duration-200"
  title="Copy invite link to clipboard"
>
  <.icon name="hero-link" class="w-5 h-5" />
</button>

<script :type={Phoenix.LiveView.ColocatedHook} name=".CopyInviteLink">
  export default {
    mounted() {
      this.el.addEventListener("click", async () => {
        const code = this.el.dataset.joinCode;
        const url = window.location.origin + "/join/" + code;
        try {
          await navigator.clipboard.writeText(url);
          // Visual feedback: show checkmark for 2 seconds
          const originalHtml = this.el.innerHTML;
          const originalClass = this.el.className;
          this.el.innerHTML = '<svg ...>✓</svg>';
          this.el.className = originalClass.replace("bg-primary", "bg-success");
          setTimeout(() => {
            this.el.innerHTML = originalHtml;
            this.el.className = originalClass;
          }, 2000);
        } catch (err) {
          console.error("Failed to copy to clipboard:", err);
        }
      });
    }
  }
</script>
```

## Consequences

### Positive
- **Clean integration:** Hooks are defined in the template where they're used, improving
  co-location and readability.
- **Hot-reload safe:** Colocated hooks are compiled into the LiveView bundle and update
  automatically on code changes.
- **Minimal JS surface:** External hooks in `assets/js/` are reserved for framework-level
  interop (e.g., event delegation, global listeners). Template-specific hooks stay local.
- **No naming collisions:** Dot-prefixed names prevent conflicts with external hooks.
- **Type-safe:** Hook data is passed via `data-*` attributes with compile-time verification.

### Negative
- **Limited reuse:** A colocated hook is tied to a single template and can't be easily shared.
  If a hook is needed in multiple LiveViews, extract it to `assets/js/` as an external hook.
- **Learning curve:** Developers unfamiliar with Phoenix v1.8 may need guidance on the pattern.

## Guidelines

1. **Use colocated hooks for:** Isolated template-specific interop (clipboard copy, drag-and-drop
   within a card, local form validation, etc.).
2. **Use external hooks for:** Shared behavior (carousel, tooltips), global listeners, or
   framework-level concerns.
3. **Always provide fallback:** Assume JavaScript might not be available (progressive enhancement).
   For non-critical features, degrade gracefully. For critical features, consider a Elixir fallback.
4. **Avoid state leaks:** Keep hook state local to `this.el`. Don't mutate global variables or
   parent elements unless necessary.
5. **Test the hook:** Use property tests to verify that button renders with the correct `data-*`
   attributes, and manual browser testing to verify the click handler works.

## References
- [Phoenix v1.8 LiveView Hooks Documentation](https://hexdocs.pm/phoenix_live_view/Phoenix.LiveView.html#module-javascript-interop)
- ADR-0005: Event Invitation System — Join Codes
