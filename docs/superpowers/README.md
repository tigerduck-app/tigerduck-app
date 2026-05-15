# Temporary Handoff Docs

These files (`plans/`, `specs/`) are local working documents shared **only as a handoff** so another contributor can pick up the iOS Widgets implementation without re-doing the planning work.

## Cleanup checklist (do this when the widget implementation lands)

1. Delete this entire `docs/superpowers/` directory.
2. Revert the `.gitignore` change that exposed it — uncomment the two lines so the patterns are active again:

   ```
   .superpowers/
   docs/plans/
   ```

   (Currently committed as `#.superpowers/` and `#docs/plans/`.)
3. Commit both changes together as a single cleanup commit.

Do **not** treat this folder as canonical documentation — it is intentionally outside the normal docs surface and will be removed.
