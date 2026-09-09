# lowlight

**bring your model. keep the conversation.**

lowlight is the terminal client. Midnight Runner is the separate model server.
Always write the client name in lowercase, including headings and launch commands.

## Terminal identity

```text
›_  lowlight                                   New conversation
/path/to/project  ·  model-name
```

The terminal logo is the reusable `LowlightLogo` SwiftTUI view in
`Sources/lowlight/LowlightLogo.swift`. A two-character prompt mark, `›_`, uses
indigo-blue. The lowercase wordmark uses the terminal's foreground. It stays on
one line at every terminal size and requires no bitmap, emoji, special font,
block art, or terminal image support.

`--ascii` or `SWIFTTUI_ASCII=1` selects this fallback:

```text
>_  lowlight
```

Use the same component on Chat, Navigator, Chats, and Help. Keep the name at
normal terminal size; the entire logo is only one row tall. Both variants
remain identifiable with color disabled.

Keep the current working directory visible below the name. Show the tagline only
on an empty connected conversation, aligned with the header and one blank row
below the workspace/model line. Anchor the input and footer at the bottom so
open space falls between the welcome text and composer.
Keep input between thin neutral horizontal rules;
brand graphics should not compete with messages or command choices.

## Palette

| Role | Light terminal | Dark terminal |
| --- | --- | --- |
| Logo and selected controls | Indigo-blue `#6574CD` | Indigo-blue `#6574CD` |
| Cursor cues | Indigo-blue `#6574CD` | Indigo-blue `#6574CD` |
| Message text | Terminal foreground | Terminal foreground |
| Wordmark | Terminal foreground | Terminal foreground |
| Supporting labels | Slate `#596273` | Silver `#A3ADBC` |
| Background | Terminal background | Terminal background |
| Errors | Red `#B33B38` | Coral `#FF938A` |

`LowlightPalette` reads SwiftTUI's detected `terminalAppearance`. Never force a
white canvas or replace that environment with a fixed app theme. Terminal color
queries supply the actual background/foreground; SwiftTUI falls back to
`COLORFGBG` or its default dark appearance if queries are unavailable.

Brand and interaction accents always use `#6574CD`: a medium indigo-blue with roughly
4.3:1 contrast against white and 4.9:1 against black. It does not change shade
with the theme. Supporting labels and errors still adapt to the background.
Body text inherits the terminal foreground, metadata stays neutral, and input
rules use the terminal's derived separator. `--no-color` remains supported.
Keep the interface to one accent family and neutrals; avoid gradients or glow effects.

## Conversation

Identify turns with compact indigo inline markers: `›` for user prompts and
`•` for agent responses. Begin each user prompt with a thin neutral horizontal
rule, followed by one blank row. Both roles use the terminal's own background
and foreground. Align prompt and response text, including wrapped lines, and
leave one blank row between messages.

Command notices use a muted dot and muted text. Keep attachments with their
message and reasoning inside its agent response. Markers and prompt rules must
preserve the distinction with `--no-color`; ASCII mode uses `>`, `*`, and `-`
for the horizontal rules.

## Assets

- `Sources/lowlight/LowlightLogo.swift`: reusable text-cell logo for the actual terminal UI.
- `Sources/lowlight/LowlightPalette.swift`: terminal-derived text and accent colors.
- `branding/lowlight-mark.svg`: graphical companion for use outside the terminal.
- `branding/lowlight-mark-mono.svg`: single-color icon for documentation and compact placements.
- `branding/lowlight-wordmark.svg`: icon and lowercase monospaced name.

The SVG mark is a companion for graphical surfaces; it is not loaded into the
terminal. SwiftTUI renders the `LowlightLogo` text cells directly.

## Commands and storage

Run `~/.lowlight/bin/lowlight`. Installed builds live under
`~/.lowlight/lib/lowlight`; recognized legacy chat launchers forward to it.
Sessions use `~/.lowlight/sessions/chat`, with existing chats still readable from the previous storage locations. Profiles and skills retain their existing `.midnight` paths. The source project can live in any checkout directory.
