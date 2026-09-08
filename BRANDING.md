# lowlight

**bring your model. keep the conversation.**

lowlight is the terminal client. Midnight Runner is the separate model server.
Always write the client name in lowercase, including headings and launch commands.

## Terminal identity

```text
◒ lowlight                                      New conversation
/path/to/project  ·  model-name
```

The mark is `◒` (U+25D2, circle with lower half black): a half-lit disc that
suggests light near the horizon. It occupies one terminal cell in common
monospaced fonts, has no emoji variation selector, and needs no icon-font install.
The terminal mark is blue and the wordmark is light cyan. Use the built-in terminal
font. Keep both at normal terminal size; no block lettering or oversized banner.
The ASCII fallback is `_ lowlight`, selected by `--ascii` or `SWIFTTUI_ASCII=1`.
The shape and wordmark identify the app even with color disabled.

Keep the current working directory visible below the name. Show the tagline only
on an empty connected conversation. Keep input between thin blue horizontal rules;
brand graphics should not compete with messages or command choices.

## Palette

| Role | Color |
| --- | --- |
| Wordmark and accents | Light cyan `#7DE3D3` |
| Mark, cursor cues, input rules | Blue `#5289E6` |
| Message text | Ink `#30343E` |
| Supporting labels | Slate `#788398` |
| Background | White `#FFFFFF` |
| Errors | Red `#BD4E40` |

Light cyan is a brand accent; ordinary response text uses ink for legibility.
Do not add purple, orange, gradients, or glow effects to the terminal interface.

## Assets

- `branding/lowlight-mark.svg`: scalable two-color icon with a transparent background.
- `branding/lowlight-mark-mono.svg`: single-color icon for documentation and compact placements.
- `branding/lowlight-wordmark.svg`: icon and lowercase monospaced name.

The SVG mark is an optical companion to the terminal glyph rather than a font
asset. Use the text glyph in terminal cells and SVGs in graphical surfaces.

## Commands and storage

Run `~/.lowlight/bin/lowlight`. Installed builds live under
`~/.lowlight/lib/lowlight`; recognized legacy chat launchers forward to it.
Sessions use `~/.lowlight/sessions/chat`, with existing chats still readable from the previous storage locations. Profiles and skills retain their existing `.midnight` paths. The source project can live in any checkout directory.
