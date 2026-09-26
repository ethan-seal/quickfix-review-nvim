---
# quickfix-review-nvim-bpi7
title: 'Setup/keymap config: uppercase types, stale maps on re-run, keymaps=false crash, qf delete map'
status: in-progress
type: bug
priority: low
created_at: 2026-09-26T12:22:52Z
updated_at: 2026-09-26T15:22:32Z
---

From review cycle 2 (details and repros: /tmp/claude-1001/-home-ethans-Programming-quickfix-review-nvim/cfc4ea53-3598-4975-b59b-e35c5f93f346/scratchpad/review2/opus-ui.md).
- commands.lua:42-45: a type key with an uppercase letter is unusable (lookups lowercase it); the WARN suggests ':ReviewAdd Bug', which fails 'Unknown comment type'; README/help claim it works. Either normalise type keys to lowercase at config time (WARN on collision) or make lookups case-exact — and fix the message/docs.
- init.lua:820-915: re-running setup() never removes old keymaps; disabled maps keep working and maps for dropped types fail. Track mapped lhs and delete them on re-run.
- config.lua:173,206: keymaps = false or export = false crashes setup() partway (signs/keymaps/commands/autocmds not set up). Accept false (disable all / disable export) or reject with a WARN and default.
- init.lua:1007: qf-window <leader>cd is hardcoded and ignores keymaps.delete_comment. Use the configured key (false disables).
- Docs: README says each default type key is <leader>c + first letter (INSIGHT is <leader>ck); cycle map desc says 'Tab' instead of +/-. Fix.

## Done when
- [ ] Test: setup twice with a map disabled the second time → map gone
- [ ] Test: keymaps=false → setup completes, no plugin maps
- [ ] Test: custom delete_comment key used in qf window
