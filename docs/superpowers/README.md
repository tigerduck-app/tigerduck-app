# docs/superpowers — 臨時交接資料

這個資料夾平常是被 `.gitignore` 擋掉的（`.superpowers/`、`docs/plans/` 兩條 rule）。
這次破例 commit 進來，是為了把 watchOS 功能的 plan / spec 交給其他人實作，讓對方可以直接照著 plan 跑 `superpowers:executing-plans`，省下重新規劃的時間。

## 目錄內容

- `plans/2026-05-12-watchos-app.md` — watchOS 完整實作 plan（task-by-task，含 checkbox 進度追蹤）
- `specs/2026-05-12-watchos-app-design.md` — watchOS 設計 spec，動工前先讀這份

## ⚠️ 完工後一定要清掉（重要）

watchOS 新功能跑完、合進主線之後，**請務必執行以下清理動作**，避免長期把這些臨時規劃文件留在 repo 裡：

1. **刪除整個 `docs/superpowers/` 資料夾**
   ```bash
   git rm -r docs/superpowers/
   ```

2. **把 `.gitignore` 改回原狀** — 目前頂部那兩條被註解掉的 rule 要恢復：
   ```diff
   -#.superpowers/
   -#docs/plans/
   +.superpowers/
   +docs/plans/
   ```

3. 一起包成一個 commit，例如 `chore: remove temporary superpowers handoff docs`。

這份 README 本身也會跟著資料夾一起被刪掉，所以不用另外處理它。
