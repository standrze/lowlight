# lowlight

![lowlight wordmark](branding/lowlight-wordmark.svg)

**bring your model. keep the conversation.**

`lowlight` is a terminal chat client for your models. It connects to Midnight Runner or another OpenAI-compatible server, with streaming answers, saved conversations, editable system prompts, and local skills.

The interface uses a compact `◒ lowlight` header, light cyan and blue accents, and a simple prompt between horizontal rules. The command and Swift executable target are both `lowlight`.

## Features

- Save, resume, search, archive, and export conversations; recover unsent drafts.
- Attach text files, edit earlier messages, retry responses, and branch a conversation.
- Change models, connection profiles, system instructions, skills, and reasoning effort.
- Keep long conversations with checkpoint summaries or a sliding context window.
- Display provider-supplied reasoning separately from answers and render basic Markdown.

lowlight connects to a separately managed model server. Skills provide instructions; the client does not execute them or run tools, MCP servers, or a REPL.

## Install a release

The first prerelease is **v0.1.0-alpha.1**, with builds for:

| Download | Target |
| --- | --- |
| `macos-arm64` | Apple silicon, macOS 15 or newer |
| `linux-x86_64` | x86_64 Linux, Ubuntu 24.04 or a compatible distribution |

The release bundles include the Swift runtime where needed; a Swift compiler is not required. Linux needs its system curl, TLS, and C/C++ runtime libraries. On Ubuntu 24.04, install missing runtime dependencies with `sudo apt-get install ca-certificates libcurl4t64 libstdc++6 libatomic1`.

This repository is private. Install [GitHub CLI](https://cli.github.com), sign in with `gh auth login`, then run this one line:

```sh
(set -o pipefail; gh api 'repos/standrze/lowlight/contents/scripts/install-release.sh?ref=v0.1.0-alpha.1' -H 'Accept: application/vnd.github.raw' | bash)
```

The installer detects your OS and architecture, downloads the matching release, verifies SHA-256, and installs into `~/.lowlight`. It adds `~/.lowlight/bin` to `.zshrc` or `.bashrc`, keeping a backup before editing. Open a new terminal and run `lowlight`.

```text
~/.lowlight/
  bin/lowlight     Stable launcher
  lib/            Installed executable, resources, and bundled runtime
  sessions/chat/  Saved conversations
  logs/           Application logs
```

Alternatively, download and extract the appropriate `.tar.gz` from [Releases](https://github.com/standrze/lowlight/releases), then run `./install.sh` inside the extracted folder. The offline installer does not edit shell configuration. Add `export PATH="$HOME/.lowlight/bin:$PATH"` yourself in that case. `--prefix PATH` changes the installation location; `--sessions-directory PATH` changes conversation storage.

These are early builds. The macOS binary is ad-hoc signed, not Apple-notarized. Intel Macs, Linux ARM64, and Alpine/musl are not included in this release.

## Build from source

Requires a Swift 6.3 or newer toolchain and the platform's development libraries.

```sh
git clone https://github.com/standrze/lowlight.git
cd lowlight
./install.sh --configuration release
```

The source installer does not change your shell configuration. Add this line to `~/.zshrc` or `~/.bashrc`, then open a new terminal:

```sh
export PATH="$HOME/.lowlight/bin:$PATH"
```

Source stays in your checkout. Recognized older lowlight launchers forward to the new installation. An OpenAI-compatible model endpoint is required for chat.

## Start a conversation

Use the model name exposed by your server:

```sh
lowlight --endpoint http://127.0.0.1:8080/v1 --model your-model-name
```

To run from source without installing:

```sh
./run.sh --endpoint http://127.0.0.1:8080/v1 --model your-model-name
```

With no arguments, the defaults are `http://127.0.0.1:8080/v1` and `gemma-4-e2b-it-4bit`. The client checks `GET /v1/models` before entering the connected state. If the server returns 404/405 for model listing, it can still use an explicitly supplied model name.

An optional `model-stack.local.json` is discovered in the process working directory or its parent (`run.sh` uses this project's directory). No local settings file is bundled or required. `--config PATH` or `MODEL_STACK_CONFIG` selects a file explicitly; command-line options override its values for new conversations.

For authenticated endpoints, set `OPENAI_API_KEY`, or use `--api-key-env NAME` to select another environment variable. Supply a plain endpoint URL without embedded credentials, query parameters, or fragments. Authentication tokens are not saved in conversation records.

Select the workspace used to discover local skills:

```sh
lowlight --workspace /path/to/your/project
```

The launcher preserves the directory it was called from as the default workspace; `--workspace` overrides it. A workspace is saved with its conversation.

Type `/` to browse commands. Up/Down selects, Tab completes, Enter completes a partial command or runs an exact command, and Escape closes the menu. Commands with arguments and multiline drafts keep normal editing behavior.

Sessions use `~/.lowlight/sessions/chat`. Profiles and skills retain their existing `.midnight` paths, documented below. See [BRANDING.md](BRANDING.md) for colors and reusable assets.

## Save and resume

Conversations autosave before and after generation, every ten seconds while streaming, and before leaving a conversation or exiting. Use `/save` to save immediately. The full transcript, completed model context and checkpoint, system prompt, selected skills, input history, workspace, and chat settings are retained. Unsent composer text and pending file snapshots save after 400 ms of inactivity and on exit. Resume that session to recover the draft, including a draft with no sent messages. Abrupt termination within the debounce interval can lose the latest keystrokes.

| Command | Behavior |
| --- | --- |
| `/save [TITLE]` | Save the current conversation, optionally naming it. |
| `/sessions [QUERY]` | Searchable picker of sessions, including matches in messages and drafts. |
| `/sessions archived [QUERY]` | Include archived sessions in the picker. |
| `/sessions archive ID` | Hide a session from the normal picker and `resume last`. |
| `/sessions restore ID` | Unarchive a session. |
| `/sessions delete ID` | Show confirmation instructions; append `confirm` to delete. |
| `/resume ID` | Resume a full UUID or unique UUID prefix. |
| `/resume last` | Resume the most recently saved valid conversation. |
| `/new [TITLE]` | Save the current chat and start another, retaining the system prompt and selected skills. |
| `/clear` | Save the current chat and start a new unnamed conversation with the same instructions. |

Resume directly at startup:

```bash
./run.sh --resume last
./run.sh --resume a1b2c3d4
```

Saved sessions use version 1 JSON files in `~/.lowlight/sessions/chat`. Override the directory with `--sessions-directory PATH`. Writes are atomic. Invalid or unsupported files remain on disk and are reported by `/sessions`; they do not hide valid conversations. The default store also reads the former `~/.midnight/sessions/chat` and `~/Library/Application Support/Midnight Chat/sessions` locations so existing chats remain resumable; new saves go to `~/.lowlight/sessions/chat`.

Resuming restores the saved model, endpoint, context policy, system prompt, skills, and workspace. Those saved values take precedence over startup settings. Authentication comes from the current environment, and usage totals restart. Interrupted responses remain visible as stopped partial text and are excluded from completed model context. Abrupt process termination can lose text since the last streaming checkpoint.

## Files, edits, and search

`/attach PATH` reads a local UTF-8 file, displays a short preview and approximate token cost, and stages its contents for the next chat message. Quoted paths with spaces are supported. Nothing is sent until you submit a message. `/attach list`, `/attach remove N`, and `/attach clear` manage pending files. Limits: eight distinct files, 128 KiB per file, 512 KiB total. Binary/control-containing files are rejected; directories are not recursively attached.

The contents are snapshots: changing or deleting the original file does not change a saved attachment, retry, or resumed draft. File contents are included in the user message and count toward the context budget. Preview notices are local; they are not included in model context. Attachments are text-only and available in chat mode, not speech mode.

| Command | Behavior |
| --- | --- |
| `/edit [TURN]` | Choose a prior user message, or its 1-based turn number, and restore it into the composer of a new branch. |
| `/retry [TURN]` | Regenerate the last turn (or selected turn) in a new branch, keeping its original prompt and attachments. |
| `/branch [TURN]` | Copy the conversation, optionally ending after the selected turn. |
| `/search TEXT` | Search user messages, answers, and reasoning in this transcript; choose a result to jump to its turn. |
| `/export PATH` | Export this session's transcript, reasoning, and attachments as Markdown; existing files are never overwritten. |

Retry and edit preserve the original session. Branching at an earlier turn rebuilds context from successful completed pairs in the retained transcript and discards the old checkpoint, which may contain later information. Failed/partial responses and local notices remain visible but are not replayed as completed answers. Rebuilt long histories may be compacted again on the next request.

Pickers use Up/Down, Enter to select, and Escape to cancel. Type to filter. Session archive/delete commands accept UUIDs or unambiguous UUID prefixes; `current` is also accepted. Deletion keeps a recovery copy in the session directory's `.trash` folder and a `.deleted` marker so legacy session locations cannot resurrect the deleted record. It does not erase the original legacy file.

## Connection profiles

Configure `/model MODEL`, `/set endpoint-url URL`, `/set context-window TOKENS`, `/set max-tokens TOKENS`, and `/set api-key-env VARIABLE`, then save the combination:

```text
/profile save local
```

`/profile` opens a picker; `/profile use local` applies a saved profile. Profiles are JSON under `~/.midnight/profiles`. Saving an existing valid profile updates it. Invalid files are left untouched. Only the authentication environment-variable name is stored, never its value.

```sh
lowlight --profile local
```

Explicit startup flags override the profile; profile values override the settings file. Resuming a session restores its own settings and saved authentication-variable name (older sessions use the startup variable).

`/model` opens the server's model picker. `/connection` shows endpoint, authentication-variable status, token reserves, and advertised capabilities; `/connection reconnect` refreshes the connection and model list. The client recognizes optional model-list metadata `context_window`, `context_length`, `max_model_len`, and `supported_reasoning_efforts`. Settings exceeding advertised limits block sending with a corrective message. Missing metadata is labeled unverified; it is not treated as proof of support. Configuring a larger client window does not increase the server/model's actual capacity.

## System prompt and skills

Set the system prompt when starting a new conversation:

```bash
./run.sh --system-prompt 'Answer concisely and state assumptions.'
./run.sh --system-prompt-file ./instructions.md
```

Use one prompt option at a time. A resumed conversation uses its saved instructions.

| Command | Behavior |
| --- | --- |
| `/system show` | Show the base system prompt and selected skill names. |
| `/system edit` | Open a multiline prompt editor; Ctrl-S applies, Escape cancels. |
| `/system set TEXT` | Replace the base system prompt. |
| `/system file PATH` | Read a UTF-8 prompt file; relative paths use this chat's workspace. |
| `/system clear` | Clear the base prompt while retaining selected skills. |
| `/skill` | Open the picker: arrows move, Space toggles, Enter applies, Escape cancels. |
| `/skill list` | List available skills and show which are active. |
| `/skill create NAME` | Edit a new project skill; Ctrl-S saves and Escape cancels. |
| `/skill use NAME` | Activate or reload a skill's instructions. |
| `/skill off NAME` | Remove one active skill. |
| `/skill clear` | Remove all active skills. |

Instruction changes preserve the conversation and apply to the next message. Active skills are included in the system instructions and consume context tokens. Browsing the catalog does not send it to the model. Activation is explicit; saved chats retain a snapshot of each selected skill, so later edits or deletion of its source file do not silently change a resumed chat. Run `/skill use NAME` to load its current version. Creation writes `<workspace>/.midnight/skills/NAME/SKILL.md`, validates the instructions, and refuses to overwrite an existing file. Creating a skill does not activate it.

Skills are discovered as `NAME/SKILL.md` beneath these roots, in precedence order:

1. `<workspace>/.agents/skills`
2. `<workspace>/.midnight/skills`
3. `~/.agents/skills`
4. `~/.config/midnight/skills`
5. `~/.codex/skills`

Duplicate names use the first valid match. Malformed files produce local diagnostics. A skill is a UTF-8 Markdown file, at most 128 KiB, with `name` and `description` frontmatter:

```markdown
---
name: concise-writing
description: Edit prose for clarity and brevity.
---
Preserve the author's meaning. Prefer concrete verbs and short paragraphs.
```

This supports local instruction files. Tool calling, MCP, script execution, and a Ruby REPL are intentionally outside this implementation.

## Long conversations

The default `checkpoint` strategy summarizes older completed turns when the next request would exceed the configured input budget, retaining recent complete turns verbatim when space permits. `/compact [GUIDANCE]` requests a checkpoint immediately, for example:

```text
/compact Preserve decisions, exact filenames, and unresolved questions.
/context
```

Compaction uses ordinary requests to the selected model and consumes tokens. Summaries can omit details; the full original transcript remains saved and visible. Failed or cancelled compaction retains the previous active context. Automatic compaction and the following response commit together only when generation succeeds.

Choose `--context-strategy slidingWindow` to omit old complete turns without automatic summary requests. Both strategies preserve the current prompt and canonical instructions. `/context` shows the active estimate and checkpoint status; `≈` marks estimates based on serialized UTF-8 bytes divided by four. See [CONTEXT.md](CONTEXT.md) for the budgeting and persistence details.

An optional settings file can configure the policy:

```json
{
  "chat": {
    "endpoint": "http://127.0.0.1:8080/v1",
    "model": "gemma-4-e2b-it-4bit",
    "maximumTokens": 512,
    "context": {
      "windowTokens": 32768,
      "safetyReserveTokens": 1024,
      "compactAtPercent": 90,
      "strategy": "checkpoint",
      "systemPrompt": null
    }
  }
}
```

Startup overrides include `--max-tokens`, `--context-window`, `--context-safety-reserve`, and `--context-compact-at`.

## Interface and runtime settings

Use `/help` for commands. Enter sends; Ctrl-N adds a newline. Shift-Enter also inserts a newline when the terminal reports that key combination. Up/Down recalls single-line input, and Tab completes slash commands. Page Up pauses automatic transcript following; Ctrl-F toggles following. Escape stops generation. Ctrl-C displays an exit confirmation (and stops generation); press Ctrl-C again to save and exit, or Escape to cancel. Ctrl-D or `/exit` saves and exits. Up/Down selects slash-menu items while the menu is open.

Use `/effort low`, `/effort medium`, `/effort high`, or `/effort default` to set the provider’s reasoning effort. This is saved with the session; provider support varies. Explicit `reasoning_content` and `reasoning` response fields appear separately under Thinking; Ctrl-T expands or hides them. Unlabeled reasoning embedded in answer text cannot be reliably separated. Assistant messages render bold, italics, headings, and code.

`/model MODEL` changes models. `/set` shows runtime settings, including:

```text
/set endpoint-url http://127.0.0.1:8080/v1
/set context-window 32768
```

Changing the model, endpoint, or context window reconnects while preserving the transcript, active context, and instructions. Usage totals restart for the new model session. `/usage` displays server-reported token counts when available through standard streaming usage reporting; it is a local command. Runner generation rates appear in the footer when supplied by the endpoint.

## Text to speech

`/mode tts` sends ordinary input to `POST /v1/audio/speech`. Audio is saved under `tts-output/` by default; playback is not implemented. Return with `/mode chat`.

```text
/set tts-model tts-1
/set voice alloy
/set audio-format mp3
/set audio-output-directory ~/Downloads/model-audio
```

Supported formats are `mp3`, `wav`, `flac`, `opus`, `aac`, and `pcm`. The output directory also accepts `--audio-output-directory PATH` or `chat.audioOutputDirectory` in the settings file. Relative output paths use the process working directory, and `~` is expanded. Saved sessions retain the chat conversation; speech mode and speech-specific settings are runtime settings.

## Verification

Run `swift test` for the core regression suite. After building, run `python3 scripts/terminal-smoke.py /absolute/path/to/lowlight` for the local terminal smoke test. It creates a mock loopback endpoint and temporary sessions, exercises attachment sending, retry/edit, draft recovery, model/session pickers, search, export, archive/restore, and confirmed deletion, and leaves its logs in the printed temporary directory.

## License

[Apache License 2.0](LICENSE).
