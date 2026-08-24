# Kaj

Docker containers in the Omarchy bar.

*Kaj* is Swedish for quay.

## Install

```bash
omarchy plugin add https://github.com/leonlarsson/omarchy-kaj.git --enable
```

Requires the `docker` CLI and a reachable daemon.

Optionally bind the panel to a key:

```lua
-- ~/.config/hypr/bindings.lua
o.bind("SUPER", "D", "omarchy-shell mozzy.kaj toggle")
```

## Keys

| Key | Action |
|---|---|
| `j` / `k` | Move between containers |
| `h` / `l` | Switch status filter |
| `Enter` | Start or stop the selected container |
| `r` | Restart |
| `o` | Logs |
| `s` | Shell |
| `p` | Pause or resume |
| `x` | Remove (asks first) |
| `Ctrl+F` or `/` | Search by name, service, project, or image |
| `Esc` | Clear the search, then close the panel |

## Settings

Set per widget in the Omarchy settings panel, or in `~/.config/omarchy/shell.json`.

| Setting | Default | Description |
|---|---|---|
| `readOnly` | `false` | Disable every action that changes a container. Status, stats, and logs still work. |
| `showStats` | `true` | Stream live CPU and memory. |
| `defaultFilter` | `all` | Status filter selected when the panel opens: `all`, `running`, `stopped`, or `problems`. |
| `notifyOnExit` | `true` | Notify when a container exits non-zero or is OOM-killed. |
| `refreshIntervalSec` | `30` | Reconcile interval. Kaj follows `docker events`, so this only bounds how long a missed event goes unnoticed. |
| `logLines` | `500` | History shown before `logs` starts following. |

## Security

The Docker socket is root-equivalent: anything that can reach it, including
every member of the `docker` group, can become root on the host. That is a
property of Docker, not of Kaj, but Kaj runs inside the long-lived shell
process, so it is written accordingly.

- Every command is an argv array. No `bash -c`, and no container name, image
  tag, or label is interpolated into a command line.
- Container state is read with `docker inspect --format`, where every value is
  `{{json .Field}}` and every key is a literal.
- Container-controlled text is rendered as `Text.PlainText` with escape
  sequences and control bytes stripped.
- Removing a container asks first, and the prompt names what is deleted and
  what is kept. Start, stop, and restart do not prompt.
- Kaj never calls `sudo` or `pkexec`.

[Rootless Docker](https://docs.docker.com/engine/security/rootless/) avoids the
root-equivalence entirely. Kaj honours `DOCKER_HOST`.

Please open an issue for security reports.

## Development

```bash
npm test                    # pure logic, no QML or Docker needed
omarchy plugin validate .
```

`Model.js` holds parsing, grouping, formatting, and policy as pure functions.
`Service.qml` talks to the daemon. `BarWidget.qml` and `Panel.qml` render.

Files under `~/.config/omarchy/plugins/` hot-reload on save. Bar widget
instances are cached, so changes to `BarWidget.qml` need `omarchy restart shell`.

## License

MIT
