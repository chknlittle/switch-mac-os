# switch-mac-os

## Overview

A custom macOS XMPP client built with SwiftUI using the **Tigase Martin** library. It renders a 4-column hierarchy (Dispatchers/Groups/Individuals/Subagents) and keeps a chat panel always visible.

## Architecture

### Four-Column Hierarchy + Always-Visible Chat

| Pane | Content | Behavior |
|------|---------|----------|
| **1** | Dispatchers | Selecting filters Groups + opens dispatcher chat |
| **2** | Groups (MUC rooms) | Selecting filters Individuals (no chat switch) |
| **3** | Individuals | Selecting filters Subagents + opens 1:1 chat |
| **4** | Subagents | Selecting opens 1:1 chat |
| **Chat** | Chat panel | Always visible; shows welcome state when no chat target |

### Selection Behavior

- **Single selection** across the 4 hierarchy panes at any time
- Selection in a parent column filters the child column(s)
- Clicking a dispatcher → shows only that dispatcher's groups in Column 2
- Clicking a group → shows only that group's individuals in Column 3
- Clicking an individual → shows that individual's subagents in Column 4
- Chat panel shows the current chat target (group selection does not change it)

### Chat Panel

- **Always visible** on the right side of the sidebar
- Shows **welcome/empty state** when nothing is selected (subtle design)
- Displays **1:1 chat** when an individual or subagent is selected
- Displays **1:1 chat** when a dispatcher is selected
- Does **not** switch the chat when a group is selected (group selection is navigation/filtering)

## Technical Stack

- **Language**: Swift
- **XMPP Library**: [Tigase Martin](https://github.com/tigase/Martin) (v3.2.1+)
  - Swift Package Manager integration
  - Modular XEP support
- **Real-time Updates**: XMPP event backbone via ejabberd
- **Platform**: macOS

## Local Development

- Copy `.env.example` to `.env` and fill in credentials.
- On macOS: open `Package.swift` in Xcode and Run the `SwitchMacOS` executable.

### Running from the command line

The app reads `.env` from the process's current working directory, so launch from the repo root:

```bash
swift build
.build/debug/SwitchMacOS
```

You can also pass env vars inline:

```bash
XMPP_HOST="..." XMPP_JID="..." XMPP_PASSWORD="..." SWITCH_DIRECTORY_JID="..." .build/debug/SwitchMacOS
```

**Note:** Values in `.env` take precedence over environment variables passed on the command line.

## Directory Service (Implemented: Option 1)

This client expects Switch to provide the hierarchy using:

- **XEP-0030 disco#items** served by a Switch "directory" XMPP account (example: `switch-dir@domain`).
- **XEP-0060 pubsub notifications** sent via ejabberd `mod_pubsub` (usually `pubsub.domain`).

The pubsub payload is treated as a lightweight "refresh ping"; the client refreshes lists by re-running disco queries.

### Node Naming

- `dispatchers`
- `groups:<dispatcherJid>`
- `individuals:<groupJid>`
- `subagents:<individualJid>`

## XMPP Features Required

### Core (Tigase Martin Built-in)
- XEP-0045: Multi-User Chat (MUC) - for groups
- XEP-0198: Stream Management - for reconnection
- XEP-0280: Message Carbons - for multi-device sync
- XEP-0313: Message Archive Management (MAM) - for history


### Contact Types (All Standard XMPP JIDs)

1. **Dispatchers** - Standard XMPP contacts
2. **Groups** - MUC rooms (XEP-0045)
3. **Individuals** - Standard XMPP contacts
4. **Subagents** - Standard XMPP contacts (spawned by other agents)

## Data Flow

```
Dispatcher selected
    ↓
Filter groups to dispatcher's groups
    ↓
Group selected
    ↓
Filter individuals to group's members
    ↓
Individual selected
    ↓
Show individual's subagents + open chat

## How We Model The 4-Column Hierarchy In XMPP

Presence/status text is good for online state, but it's not a reliable place to encode durable classification (dispatcher vs session vs subagent) or parent/child relationships.

Decision: use standard discovery + subscriptions, with Switch as the source of truth.

- **Directory service (required)**: Switch runs an XMPP account that supports:
  - XEP-0030 (Service Discovery) to list items for each level
- **PubSub (required)**: ejabberd `mod_pubsub` pushes realtime "refresh" signals (XEP-0060)
  - The service returns structured lists:
    - dispatchers
    - groups for a dispatcher
    - individuals for a group
    - subagents for an individual
- **Client behavior**: the client renders columns from directory results; it uses standard message/presence/roster for chat + online indicators.

## Subagent Final Response Behavior

Subagents are treated like normal XMPP contacts for chat/presence. The key behavioral difference is that a subagent's work output must be delivered back to the agent/contact that spawned it.

- Work messages include a task id and parent reference (e.g. `task_id`, `parent_jid`).
- The subagent sends the final response to `parent_jid` (and optionally also to the currently active chat, depending on UX).
```

## UI States

### Welcome/Empty State
- Subtle, minimal design
- Displayed when no selection active
- No chat content shown

### Active Chat State
- Chat header shows contact/room name
- Message history loaded via MAM
- Real-time message delivery
- Typing indicators (optional)

## Future Considerations

- Subagents primarily exist to do work for their parent session/contact
- Backend assumes support for agent spawning
- All contact types use standard XMPP protocol
