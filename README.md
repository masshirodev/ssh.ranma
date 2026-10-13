# ssh.ranma

A plugin for [ranma](https://github.com/masshirodev/ranma), the terminal tiling window manager: a picker over the hosts in your `~/.ssh/config`. Enter goes to the pane already connected there, or opens a workspace running `ssh <host>`. A pane whose server stopped answering gets a badge.

Needs ranma v0.2.2 or newer, on Linux (connections are found through `/proc`).

## Install

With [hako](https://github.com/masshirodev/hako.ranma), in `~/.config/ranma/lua/plugins/ssh.lua`:

```lua
return { "masshirodev/ssh.ranma" }
```

Or by hand, as ranma loads any package under `pack/*/start/`:

```sh
git clone https://github.com/masshirodev/ssh.ranma ~/.config/ranma/pack/plugins/start/ssh.ranma
```

Needs: `ssh`, `sh`, `pgrep` and `tr`.

## What it does

```text
ssh: a picker over the hosts in ~/.ssh/config.

leader R   (shift+r) lists every Host in ~/.ssh/config and the files it
           Includes (patterns such as `*` or `*.lan` left out), its
           HostName on the right. Hosts this ranma already has an ssh to
           are marked ● and listed first. Enter goes to the pane already
           connected there (in any session), or opens a workspace running
           `ssh <host>`; ranma names the workspace after the destination.
           With ssh.open = "pane", it splits the focused pane instead.
In the palette (leader :): `ssh [host]`, completing the hosts; with a
host, it goes there without a picker. `ssh !host` (or the picker's
second line for a connected host, `new`) opens another connection even
when one exists.
Another key: ranma.bind(KEY, function() ranma.emit("ssh") end), or with a
host as the data to go there.

A connection that fails leaves its pane up with ssh's exit status until
Enter, so the error can be read; one that ends normally closes it.

With ssh.badges on, a pane whose screen shows ssh giving up on a server
(`Timeout, server … not responding`, `client_loop: send disconnect`,
`Connection to … closed by remote host`, `Broken pipe`) gets a badge,
`✗ lost`, while ssh is still the pane's program (the same words printed
by anything else are not a loss). It goes when a command starts or
finishes there, when ssh is no longer in the foreground (seen on focus or
when the pane goes quiet), or when the pane closes. ServerAliveInterval in
the config is what makes ssh notice.

Which panes are connected where: the ssh processes whose RANMA_PANE is a
pane of this server, and their destination as typed (`ssh vps`, `ssh -p 22
me@vps`): read from /proc when the picker opens, never on a timer. Linux
only; elsewhere every host is listed as not connected.

Needs ranma 0.2.2 or newer.

ranma's plugin API: https://github.com/masshirodev/ranma/blob/main/doc/CONFIG.md ("Pickers and
prompts", "Pane handles", "Timers and processes", "Hooks").
```

## Binds and commands

| Key / command | |
| --- | --- |
| `leader R` (shift+r, plugins group) | The picker of hosts. A connected one asks: go to it, or open another connection. |
| `ssh` in the palette (`leader :`) | The same picker. |
| `ssh HOST` | Go to HOST's connection, or open one, without a picker. Completes the hosts. |
| `ssh !HOST` | A new connection to HOST, even with one open. |

Another key, in `init.lua` after the plugin loads:

```lua
ranma.unbind("shift+r")
ranma.bind("<key>", function() ranma.emit("ssh") end, { desc = "ssh", exit = true })
```

## Options

In ranma's settings panel under `ssh`, or with hako's `opts`, or `ranma.set { ssh = { ... } }`.

| Option | Default | |
| --- | --- | --- |
| `ssh.config` | `"~/.ssh/config"` | The config read for hosts; its `Include` lines are followed, in place, as ssh reads them. |
| `ssh.open` | `"workspace"` | A new connection opens in an empty workspace, or (`"pane"`) split from the focused pane. |
| `ssh.badges` | `true` | Mark a pane whose screen shows ssh losing its server: `✗ lost`. |

## How it reads the config

`Host` lines give the names; a name with `*`, `?` or `!` is a pattern and is left out. `HostName`, `User` and `Port` belong to the `Host` block they are in, and the first value given wins, as in ssh, across included files too: an `Include` is read where it stands, with its globs expanded by the shell. `Match` blocks are skipped. Nothing else of the config is interpreted; `ssh` itself does the connecting.

## Costs

The config is read and `/proc` scanned when the picker opens, never on a timer. The badge is a `pane:watch` per pane, which ranma looks at on output only, at most every 100 ms, over the screen.

## Limits

- A connection is found by its ssh process: `ssh` in the pane, with the destination as typed. One made through a wrapper that is not called `ssh` (or `mosh`) is not seen as connected.
- The badge comes from what ssh prints when it gives up, so it needs ssh to notice: set `ServerAliveInterval` (and `ServerAliveCountMax`) in the config.

## License

MIT or Apache-2.0, as ranma.
