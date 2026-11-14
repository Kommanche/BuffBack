# BuffBack tests

These tests run BuffBack's Lua outside the game against a small WoW API stub. They cover queue priority, caster attribution, secret-aura handling, refresh detection, recipient skip rules, cast success/failure, party reminders, preview versus real casting, and the reported Blessing of Kings case.

They are not loaded by the addon (`BuffBack.toc` lists only `BuffBack.lua`).

## Run

Requires Node.js. From this folder:

```powershell
npm install --no-save fengari-node-cli
.\node_modules\.bin\fengari.cmd test_core.lua
.\node_modules\.bin\fengari.cmd test_behavior.lua
```

Both scripts print `PASS`/`FAIL` per check and exit non-zero on failure. The harness loads `../BuffBack.lua`, so keep the tests folder inside the addon folder.

`luaparse` is not required for the tests, but `npx --yes luaparse ../BuffBack.lua` is a quick syntax check.
