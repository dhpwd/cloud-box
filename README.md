# Cloud box

> **26/10/2026:** Tailscale SSH has an unfixed root-escalation bug (Tailworm). Follow [issue #1](https://github.com/dhpwd/cloud-box/issues/1) to turn it off until Tailscale releases a fix.

Build scripts and shell helpers for a persistent Linux box that runs coding agents (Claude Code, Codex CLI, Gemini CLI) inside tmux, with the laptop and phone as terminals into it. The why and the design are in the blog post: [Running coding agents on a €30 Linux box](https://danhopwood.com/posts/running-coding-agents-on-a-30-euro-linux-box).

The stack, one line each: a plain VPS (Netcup, 32GB), Tailscale with no public ports, mosh, tmux with one session per project, config from a git-backed dotfiles repo, secrets from a 1Password service account, Playwright MCP for a browser. The box is primary and nothing syncs – the laptop keeps a checkout under one rule: git-backed work only, commit and push before switching back.

## What's here

```
scripts/   the build, in order – run on the box
shell/     laptop-side helpers (box, boximg, sweep) and the git and prompt config both machines share
```

The tmux config, the box-side helpers (`t`, `sweep`, the `claude` wrapper) and the theme fix are written by `scripts/05-tmux-and-shell.sh`, so read that file for them. On the laptop, source `shell/laptop.zsh` from `~/.zshrc`, add `shell/gitconfig` as a global `include.path`, point `core.excludesFile` at `shell/gitignore` and symlink `shell/starship.toml` to `~/.config/starship.toml`. The helpers need `mosh`, `fzf`, `fd`, `bat`, `starship` and `pngpaste` from Homebrew.

These are my real scripts with my identifiers swapped for placeholders, so expect to edit the repo list in `03-repos.sh`, the MCP server set in `04-mcp.sh` and the agent aliases in `05-tmux-and-shell.sh`. `BOX_USER` (default `dan`) is the non-root user the agents run as.

## Order of operations

Start from a fresh Debian 13 host with root SSH. Ordering the box itself is a manual checkout.

```
laptop:  scp -r scripts root@<ip>:/root/ && ssh -t root@<ip> bash /root/scripts/01-base.sh
box:     /root/scripts/02-tailscale-lockdown.sh up          # as root
laptop:  ssh <user>@<magicdns-name>                          # prove the tailnet works
box:     /root/scripts/02-tailscale-lockdown.sh close       # keep the tested session open as a way back
box:     git clone https://github.com/dhpwd/cloud-box && cd cloud-box/scripts   # as the user, from here on
box:     ./03-repos.sh && ./04-mcp.sh && ./05-tmux-and-shell.sh && ./06-supervisor.sh
```

| Script                           | Runs on          | Needs you                                                            |
| -------------------------------- | ---------------- | -------------------------------------------------------------------- |
| `01-base.sh`                     | box, as root     | sets the user password interactively – needs `ssh -t`                |
| `02-tailscale-lockdown.sh up`    | box, as root     | approve the machine in the Tailscale console                         |
| `02-tailscale-lockdown.sh close` | box, as root     | confirms before closing public SSH                                   |
| `03-repos.sh`                    | box, as the user | `gh auth login` first (HTTPS, no SSH key needed)                     |
| `04-mcp.sh`                      | box, as the user | `OP_SERVICE_ACCOUNT_TOKEN`, a populated vault, OAuth redirect pastes |
| `05-tmux-and-shell.sh`           | box, as the user | –                                                                    |
| `06-supervisor.sh`               | box, as the user | –                                                                    |

Between the scripts there is manual work with nothing to script: a 1Password vault holding every token the box needs plus a service account scoped to it (before `04`), `/login` for Claude Code and `codex login` (before `05`), and, on the phone, the Tailscale iOS app and then Termius with SSH and mosh both enabled.

Two things the scripts fix that only showed up when running them: `op read` on an empty field exits 0, so `04-mcp.sh` tests the value it gets back, not the exit code. And Tailscale SSH is a separate listener that never consults sshd's config, so the sshd hardening in `02` constrains only the plain-SSH path – the control for Tailscale SSH is the tailnet policy. Split the default rule into your user on `accept` and `root` on `check` with a short `checkPeriod`.

## If you lock yourself out

`02-tailscale-lockdown.sh close` is the only step that can. It arms a revert before it runs: unless a second prompt confirms a fresh connection worked, the whole change is undone after 300 seconds, so a wrong rule costs a five-minute wait rather than a trip to the provider's remote console. If it does come to that: delete `/etc/ssh/sshd_config.d/99-tailscale.conf` and run `ufw disable`.

## Secrets

Nothing in this repo holds a secret value. `04-mcp.sh` reads every one from 1Password at run time via `op read` and `op document get`. The Typefully MCP server takes its key as a URL query parameter, so it ends up in the clear in `~/.claude.json`. Rotate it during the move and keep the new one in 1Password only.

## Licence

MIT.
