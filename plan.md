# naur.el MVP Spec

## Problem

Agentic coding tools treat humans as reviewers of large diffs rather than participants in design and implementation. The result: engineers lose understanding of their own codebases, incremental progress gives way to batch generation, and collaboration between humans gets harder because no shared design artifact exists.

## Goal

An Emacs workflow where a human and an LLM agent co-author code through an org-mode design document that serves as both the plan and the record. The human stays in the loop at every level of abstraction — from system-level architecture down to individual functions — and the org file provides a durable, navigable artifact that any collaborator can read to understand what was built and why.

LLM backends: primarily OpenRouter, with support for ChatGPT and z.ai as alternative providers via gptel's multi-backend configuration.

## Core Concepts

### The Org Spine

Lives in `naur/` at the project root (committed to git). One org file per project or major subsystem. `naur-mode` looks here by default; prompts only if the directory doesn't exist yet.

A single org file evolves through phases:

1. **Ideation** — free-form conversation captured as org subtrees
2. **Architecture** — headings representing system boundaries, data flows, key decisions
3. **Specification** — headings representing modules, interfaces, and behaviors with enough detail to implement
4. **Implementation** — headings linked to code via `CODE_REF` properties, conversation history preserved in drawers

Each heading carries properties:

```org
* Authentication middleware
:PROPERTIES:
:STATUS: implementing
:OWNER: both
:CODE_REF: src/middleware/auth.go::15-48
:END:

:CONVERSATION:
[gptel conversation history for this subtree]
:END:

Design notes, decisions, constraints in body text.
```

Valid `STATUS` values: `ideating`, `specified`, `implementing`, `integrated`, `revised`.
Valid `OWNER` values: `human`, `agent`, `both`.

### CODE_REF Format

References use the form `file::start-end` for line ranges or `file::symbol` for named definitions:

```
src/middleware/auth.go::15-48
src/models/user.go::UserFromToken
```

Multiple refs separated by commas. These are maintained manually or by the agent via tool calls. They will drift as code changes — the agent should flag drift when it notices (e.g., a CODE_REF points to lines that no longer match the heading description) but automated drift detection/repair is a later problem.

### Shared Focus

The human indicates focus to the agent through two mechanisms:

- **Point location** — which org heading the cursor is in, or which file and line the cursor is on
- **Active region** — selected text in either the org buffer or a code buffer

The agent indicates focus to the human through:

- **Referencing org headings** by name in conversation
- **Citing file:line spans** in responses, rendered as clickable links that jump to the location

No ambient tracking. Focus is read when the agent is invoked, not streamed continuously.

## Architecture

### Window Layout

```
+----------------------------+------------------+
|                            |                  |
|   Main area                |  Side window     |
|   (org file or code)       |  (gptel chat)    |
|                            |                  |
|                            |                  |
+----------------------------+------------------+
```

The side window is pinned right via `display-buffer-in-side-window`. The main area holds whatever the user is editing — the org spine, a code file, or both in a vertical split. The gptel buffer is dedicated to the current project's conversation.

### Components

```
naur.el
├── naur-layout.el          ;; window management, mode definition
├── naur-context.el         ;; focus capture (point, region, heading)
├── naur-nav.el             ;; CODE_REF navigation
├── naur-tools.el           ;; gptel tool definitions
└── naur-org.el             ;; org property helpers, agenda integration
```

### Dependencies

- **gptel** — LLM interaction, org-mode branching context, tool-use
- **org-mode** — built-in
- No other external dependencies for MVP

### Packaging

Installed from GitHub via straight.el. Dependencies declared in `Package-Requires` header:

```elisp
;; Package-Requires: ((emacs "28.1") (gptel "0.9"))
```

No Cask for now. Add later only if CI needed for running tests in clean environment.

### Preliminary Step: Verify gptel Tool-Use API

Before implementation begins, verify the current `gptel-make-tool` interface (or equivalent) matches what this spec assumes. gptel's tool-use API is still evolving — confirm registration mechanism, tool schema format, and how tool results are returned to the LLM. Document any deviations and adjust the naur-tools.el design accordingly.

## Detailed Design

### naur-layout.el

**`naur-mode`** (minor mode): interactive entry point. When activated, prompts for the project org file if not already set, opens the org file in the main window and the gptel buffer in the right side window, sets up the side-window rule, and provides the keymap. Stores the association between the org file and the gptel buffer in a project-local variable. Deactivating the mode tears down the layout.

**`naur-toggle-chat`**: shows/hides the side window.

### naur-context.el

**`naur--capture-context`**: called internally when a gptel tool requests context. Returns an alist:

```elisp
(:heading     "Authentication middleware"   ;; nearest org heading, if in org buffer
 :heading-path ("System" "API" "Auth...")   ;; full outline path
 :status       "implementing"              ;; from PROPERTIES
 :file         "src/middleware/auth.go"     ;; if in a code buffer
 :line         34                           ;; current line
 :region       "func validateToken..."     ;; active region text, or nil
 :code-ref     "src/middleware/auth.go::15-48") ;; from PROPERTIES, if in org
```

This is computed fresh on each tool invocation. No caching, no background updates.

### naur-nav.el

**`naur-goto-code-ref`** (`C-c n g`): when point is on an org heading with a `CODE_REF` property, opens the referenced file and jumps to the line range or symbol. If multiple refs, prompts with completing-read.

**`naur-set-code-ref`** (`C-c n r`): sets the `CODE_REF` property on the current heading to `current-buffer::current-line` or the active region's span.

**Clickable refs in chat**: gptel response text containing `file::line` patterns gets font-locked with a keymap — `RET` or click calls `naur-goto-code-ref` on them. This is a simple `font-lock-keywords` addition to the gptel buffer.

### naur-tools.el

Registered with gptel as tools available to the agent. These are the agent's interface to the workspace.

**`get_context`**: returns the output of `naur--capture-context` as JSON. The agent calls this to understand what the human is looking at.

**`read_file`**: args `(file, start_line, end_line)`. Returns the contents of the specified line range. The agent uses this to read code the human is pointing at or that a CODE_REF references.

**`read_heading`**: args `(heading_path)`. Returns the full content of the org subtree at the given path — body text, properties, child headings (but not conversation drawers). Lets the agent review design context.

**`list_headings`**: args `(min_level, max_level, status_filter)`. Returns a flat list of headings with their status, owner, and CODE_REFs. The agent uses this to understand project structure and find what needs work.

**`propose_edit`**: args `(file, start_line, end_line, new_content, description)`. Displays a diff to the human in a temporary buffer and asks for confirmation. On accept, applies the edit. On reject, returns rejection to the agent. The human always approves code changes.

**`update_heading`**: args `(heading_path, property, value)`. Updates a property (STATUS, OWNER, CODE_REF) on an org heading. The agent uses this to track progress as implementation proceeds.

### naur-org.el

**Agenda integration**: a custom agenda command that shows all headings filtered by STATUS. Useful for seeing what's specified but not yet implemented, what's in progress, etc.

**Capture template**: `org-capture` template for adding a new heading to the spine with STATUS defaulting to `ideating`.

**Status cycling**: `C-c n c` cycles STATUS on the current heading through the valid values.

## Keybindings (under `C-c n` prefix)

| Key       | Command                  | Context        |
|-----------|--------------------------|----------------|
| `C-c n n` | Activate naur-mode       | global         |
| `C-c n t` | Toggle chat window       | naur-mode      |
| `C-c n g` | Go to CODE_REF at point  | org buffer     |
| `C-c n r` | Set CODE_REF from here   | code buffer    |
| `C-c n c` | Cycle STATUS             | org buffer     |
| `C-c n a` | Show naur agenda         | global         |
| `C-c n s` | Start agent conversation | naur-mode      |
| `C-c n l` | Resume last conversation | naur-mode      |

### Agent Invocation

Two commands control conversation flow:

**`naur-start-agent`** (`C-c n s`): begins a new agent conversation. Captures current context (point, region, heading), opens the gptel buffer in the side window if not visible, and sends the context as the opening system message. The user then types their prompt in the gptel buffer.

**`naur-resume-conversation`** (`C-c n l`): resumes the last conversation in the gptel buffer for this project. Refreshes context from current point/region so the agent sees where the human is now, but continues the existing conversation thread rather than starting fresh.

Both commands work from either the org buffer or a code buffer — context capture adapts to whichever is active.

## Interaction Flow (Example)

1. User activates `naur-mode`, picks `~/proj/spine.org`. Layout opens.
2. User invokes `naur-start-agent`, types: "I need an HTTP API for user auth — JWT-based, middleware pattern, Go."
3. Agent responds with a proposed org structure: top-level headings for middleware, token service, user model. Asks if this looks right.
4. User refines. Agent calls `update_heading` to set statuses to `specified` as design solidifies.
5. User navigates to "Token service" heading, selects the interface sketch in the body text, invokes `naur-start-agent`.
6. Agent calls `get_context`, sees the selected interface sketch, proposes code via `propose_edit` to `src/auth/token.go`.
7. User reviews diff, accepts. Agent calls `update_heading` to set STATUS to `implementing` and CODE_REF to `src/auth/token.go::1-35`.
8. User jumps to the code with `C-c n g`, reads it, edits by hand, comes back to the org file.
9. User runs `naur-resume-conversation` to continue where they left off with fresh context.
10. Cycle continues heading by heading until the subtree is `integrated`.

## What This Is Not

- **Not real-time collaboration.** Multi-human is handled by committing the org file to git. Merge conflicts on org files are manageable because the structure is heading-scoped.
- **Not a code generator.** The agent proposes edits; the human approves or writes code directly. The org spine is the primary artifact, not the generated code.
- **Not a project management tool.** STATUS tracking is minimal and in service of the design workflow, not sprint planning.

## Open Questions for Dogfooding

- How granular should headings get? One per function is too fine; one per subsystem is too coarse. Probably emerges from use.
- CONVERSATION drawers store decisions only (not full transcripts). gptel handles ephemeral conversation history. Revisit if decision logs prove insufficient.
- Is `propose_edit` with a diff buffer the right confirmation UX, or is something lighter (inline overlay in the code buffer) better?
- How badly does CODE_REF drift matter in practice, and when does it become worth solving?
