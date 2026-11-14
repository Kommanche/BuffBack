# BuffBack

BuffBack prompts you to buff back another player in **World of Warcraft: Forever**. It is click-to-cast: the addon never casts on its own, never changes your target, and never guesses who buffed you.

Typical case: another player buffs you while passing by, so a small icon appears with their name. Click it to give them one of your buffs back.

## Requirements

- World of Warcraft: Forever, interface **16001**.
- The addon works for any class that can cast a friendly buff. Automatic selection covers druid, mage, priest, and paladin; everyone else picks a spell once.

## Install

1. Copy this folder to `Interface/AddOns/BuffBack` so that `BuffBack.toc` and `BuffBack.lua` sit directly inside it.
2. Restart the client or reload the UI, then enable **BuffBack** in the AddOns list.
3. `/reload` after updating the Lua file.

## What it does

### Buff-back prompt (primary)

When another player gives you a helpful buff, BuffBack names the caster and offers to return the favour. Click the icon to cast your own buff on that player. Your current target is not changed.

- The prompt clears only after a cast the client reports as **successful**, or when you dismiss it.
- A failed or rejected cast leaves the prompt in place, so you can try again.
- Prompts expire after 60 seconds.
- If the player is no longer a usable unit, the prompt is hidden while the request remains queued. It can reappear if they become available before it expires.

### Self and party reminders (secondary)

BuffBack also checks whether **you** and your **visible, living party members** are missing your buff.

- Reminders appear only when the member is in spell range.
- They never replace a buff-back prompt; the number of waiting reminders is shown as `(+1)`, `(+2)`, and so on.
- Dismissing a reminder pauses that member for 60 seconds.
- In a raid, only your own reminder is generated; party reminders are limited to party play.

## Supported buffs

Automatic selection checks your spellbook as you learn spells:

| Class | Buff |
| --- | --- |
| Druid | Mark of the Wild (Gift of the Wild counts) |
| Mage | Arcane Intellect (Arcane Brilliance counts) |
| Priest | Power Word: Fortitude (Prayer of Fortitude counts) |
| Paladin | Blessing of Kings, falling back to Blessing of Might |

Other classes, or a preferred spell, use `/buffback spell <ID>` with a numeric spell ID your character knows. The addon rejects self-only spells. Use `/buffback auto` to go back to automatic selection.

## Using the prompt

| Action | Result |
| --- | --- |
| Left-click | Cast your buff on the named player |
| Right-click | Dismiss the prompt (party/self reminders pause for 60 seconds) |
| Shift-drag | Move the icon; the position is saved per character |

The button is hidden during combat. Queued prompts are rechecked when combat ends.

## Commands

| Command | Effect |
| --- | --- |
| `/buffback` | Show help |
| `/buffback status` | Selected buff, aura readability, baseline state, queue, active prompt, and recent misses/skips |
| `/buffback test` | Show a non-casting preview |
| `/buffback casttest` | Show a real cast prompt for your current friendly target |
| `/buffback spell <ID>` | Use a specific spell you know |
| `/buffback auto` | Restore automatic selection |
| `/buffback clear` | Clear prompts and pause self/party reminders for 60 seconds |
| `/buffback debug` | Toggle detection messages in chat (resets on reload) |

`/buffback test` and `/buffback casttest` are deliberately separate: the preview can never cast, while `casttest` exercises the real secure cast button. Both are unavailable in combat; `casttest` also requires a current friendly target.

## Troubleshooting

**No prompt after someone buffed me.** First check `/buffback status`:

- `auras: hidden by client` means the client is withholding aura data (restricted content, or transiently during events such as a level-up). BuffBack pauses detection and retries.
- "Last detected buff without a usable caster" means the client did not expose who cast the buff; BuffBack deliberately does not guess.
- If the buff was received during combat, it is rebaselined afterwards and cannot be attributed. This is a client restriction.
- If the incoming buff changed nothing (the same buff was already present with a longer duration), the client may not fire any aura event, so there is nothing to detect.

**The prompt disappeared before I could click.** The player may no longer be a usable unit. If they become available before the request expires, the prompt can reappear.

**The icon stayed visible after a cast.** The success event does not identify a recipient, so the addon matches a recent click by spell ID or spell name. If the client reports a different spell, or the cast happened in combat (where the button cannot change state), the prompt may remain until combat ends or it expires.

**A prompt appeared for someone who already has my buff.** This can only happen when the client withholds their aura data, because the addon then cannot know. With readable aura data, the prompt is skipped.

**No party reminders.** Reminders require a party (not a raid), a visible and living member, known spell range, and readable aura data. Out-of-range members are suppressed by design.

## Limits

- **Caster info.** The client may withhold the caster, return a caster with no usable unit token, or hide the aura entirely. BuffBack reports the miss instead of guessing.
- **Secret auras.** In restricted content and transiently during events such as level-ups, the client marks aura data secret. BuffBack pauses detection instead of erroring, retries, and recovers buffs whose `UNIT_AURA` payload was unreadable by periodically re-scanning outside combat.
- **Combat.** Aura changes during combat are rebaselined when combat ends, because they cannot be attributed reliably.
- **Cast confirmation.** The success event does not identify a recipient, so a different cast of the same spell within 10 seconds could also clear the prompt. A failed click never clears it.
- **Stale unit tokens.** Before casting, the target's GUID is checked again against the prompt. If the token now points at someone else, the secure action is disabled outside combat. In combat the button cannot change its attributes, so the pre-combat assignment is used.
- **Range and rules.** Range, line of sight, cooldowns, mana, and class restrictions are enforced by the game. Out-of-range party reminders are suppressed; an out-of-range click still attempts the cast.

## Development

The source folder includes a `tests` directory with logic tests that run outside the game against a WoW API stub. It is not loaded by the addon (`BuffBack.toc` lists only `BuffBack.lua`). See `tests/README.md` for how to run them.

After entering the world, BuffBack baselines existing auras for at least five seconds; buffs received during this settling period may not produce a return prompt. If a return-buff caster is no longer available, the prompt stays hidden while the request remains queued (up to 60 seconds) and can reappear if the caster becomes resolvable.
