# naur.el

Co-author code with an LLM through org-mode design documents.

naur.el provides a workflow where a human and an LLM agent collaborate through an org-mode "spine" file that serves as both the architecture document and the work log. The human stays in the loop at every level of abstraction, and the spine provides a durable, navigable artifact that any collaborator can read to understand what was built and why.

## Requirements

- Emacs 28.1+
- [gptel](https://github.com/karthink/gptel) 0.9.8+

## Installation

With straight.el:

```elisp
(straight-use-package '(naur :type git :host github :repo "chazu/naur.el"))
```

Then in your config:

```elisp
(require 'naur)
(naur-setup)  ; register tools with gptel
```

## Usage

1. `M-x naur-mode` (or `C-c n n`) in any project buffer
2. naur finds or creates a spine file in `naur/` at the project root
3. Layout opens: spine/code on the left, gptel chat on the right
4. The agent auto-orients by reading context, then waits for your prompt

## Key Bindings

All under the `C-c n` prefix when `naur-mode` is active:

| Key       | Command                     | Context    |
|-----------|-----------------------------|------------|
| `C-c n n` | Activate naur-mode          | global     |
| `C-c n t` | Toggle chat window          | naur-mode  |
| `C-c n g` | Go to CODE_REF at point     | org buffer |
| `C-c n r` | Set CODE_REF from here      | code buffer|
| `C-c n c` | Cycle STATUS                | org buffer |
| `C-c n a` | Show naur agenda            | global     |
| `C-c n A` | Archive conversation        | org buffer |
| `C-c n f` | Toggle fold at point        | chat buffer|
| `C-c n s` | Start agent conversation    | naur-mode  |
| `C-c n l` | Resume last conversation    | naur-mode  |

## How It Works

### The Spine

An org file in `naur/` at the project root. Headings represent system boundaries at varying levels of abstraction. Each heading carries properties:

- **STATUS**: `ideating` | `specified` | `implementing` | `integrated` | `revised`
- **OWNER**: `human` | `agent` | `both`
- **CODE_REF**: bidirectional link to code (`file::start-end` or `file::symbol`)

### Agent Tools

The agent has access to these tools via gptel:

| Tool | Description |
|------|-------------|
| `get_context` | Read human's current focus (file, heading, selection) |
| `read_file` | Read file contents and display the file in the left pane |
| `read_heading` | Read spine heading content (excludes conversation drawers) |
| `list_headings` | List headings with status, owner, code refs |
| `search` | Grep across project files |
| `read_conversation` | Read a heading's CONVERSATION drawer |
| `append_conversation` | Append to a heading's CONVERSATION drawer |
| `apply_edit` | Apply a code edit directly, display result in left pane |
| `propose_heading` | Propose a new spine heading (requires confirmation) |
| `update_heading` | Update heading properties (STATUS, OWNER, CODE_REF) |

### AGENTS.md

Agent behavior instructions live in `AGENTS.md` at the project root (not baked into elisp). Created automatically from a bundled template on first spine creation. Edit it per-project to tune agent behavior.

### Auto-Context Refresh

The system message is refreshed with current cursor context on every gptel send, not just on start/resume. Move your cursor to a different heading or code file, type in the chat, and the agent sees your new focus automatically.

### Conversation Archiving

`C-c n A` archives a heading's CONVERSATION drawer to `naur/conversations/`, optionally summarizing it via LLM. The drawer is replaced with an org link to the archive file.

## Configuration

```elisp
;; gptel backend/model for naur chat (nil = gptel defaults)
(setq naur-backend "OpenRouter")
(setq naur-model "anthropic/claude-sonnet-4-20250514")

;; Chat window width (fraction of frame)
(setq naur-chat-window-width 0.35)

;; Disable auto-orientation on start/resume
(setq naur-auto-orient nil)

;; Custom system prompt (overrides AGENTS.md)
(setq naur-base-prompt "Your custom prompt here")

;; Disable LLM summarization on archive
(setq naur-archive-summarize nil)
```

## Project Structure

```
naur.el
├── naur.el              ;; entry point, requires all modules
├── naur-layout.el       ;; window management, mode definition, prompt loading
├── naur-context.el      ;; focus capture (point, region, heading)
├── naur-nav.el          ;; CODE_REF navigation, clickable refs
├── naur-tools.el        ;; gptel tool definitions
├── naur-org.el          ;; org property helpers, agenda, archiving
├── naur-fold.el         ;; fold reasoning/tool blocks in chat
├── spine-template.org   ;; template for new spine files
└── agents-template.md   ;; template for AGENTS.md
```

## License

GPL-3.0
