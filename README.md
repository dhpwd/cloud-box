# Cloud box

> **27/10/2026:** Tailscale v1.104.4 fixes the Tailscale SSH root-escalation bug (Tailworm). If you built a box before then, update Tailscale and follow [issue #1](https://github.com/dhpwd/cloud-box/issues/1) to check Tailscale SSH is back on.

The scripts I run to set up a cloud box for someone, and the do-it-yourself route for anyone who wants to build their own. Run on a fresh Debian 13 server with the inputs file filled in and no script edited, they produce a box whose Claude Code sessions you start and continue from the Claude desktop and phone apps through Remote Control. Your repos, your Claude Code config and the key-based connectors you choose are on it, the agents run as an account without admin rights, and nothing on the box is open to the internet except through Tailscale.

The owner never needs a terminal once the box is built. The why behind the setup is in the blog post: [Running coding agents on a €30 Linux box](https://danhopwood.com/posts/running-coding-agents-on-a-30-euro-linux-box).

## Two roles

- **The operator** builds the box. That's me when I set one up for you, or you when you build your own
- **The owner** holds the accounts: the server, Tailscale, Claude, GitHub, the laptop and the phone

A step on the owner's laptop is run by whoever is at its keyboard. When I build a box for you, that can be me, under keyboard control you grant on the call. The scripts don't depend on which.

## Before you start

**The server.** A Netcup VPS 2000 G12.5 (8 vCores, 16GB RAM, 256GB SSD) with the Debian 13 minimal image, on a 1-month term, at about €31 a month including UK VAT (netcup.com, read 21/11/2026). Add the operator's SSH public key at checkout. Netcup warns that provisioning can be slow, so order it a few days ahead.

**The owner needs:**

- A paid Claude plan. On a Team or Enterprise plan, an Owner of the Claude organisation turns on the Remote Control toggle at [claude.ai/admin-settings/claude-code](https://claude.ai/admin-settings/claude-code) first – it is off by default
- Their work in GitHub
- A Tailscale account, and the Tailscale app on the laptop
- The Claude app on their phone
- A Mac or Linux laptop. `laptop/push.sh` doesn't run on Windows

**The operator needs:** the server's IP address, the repo list, the names of the connectors to bring across (`laptop/push.sh` lists them by name when it runs without `--connectors`, and `claude mcp list` would show their keys on a shared screen), and any env files or folders with no git remote, with where each one goes on the box.

## The inputs

Everything that differs between owners lives in one file, `box.env` at the repo root, which every script reads. Copy `box.env.example` and fill it in. An environment variable of the same name wins over the file, even an empty one. The file holds no secret, and git ignores it.

| Input             | Required | What it is                                                                                                                                    |
| ----------------- | -------- | --------------------------------------------------------------------------------------------------------------------------------------------- |
| `BOX_USER`        | yes      | The account the agents run as. Not `root`. It gets a locked password and no `sudo`                                                            |
| `OPERATOR_PUBKEY` | yes      | The operator's SSH public key, one line. `01-base.sh` lets it sign in as `BOX_USER`, and `06-handover.sh` removes it from root and `BOX_USER` |
| `REPOS`           | yes      | The repos, space-separated, each `<local dir>=<github owner/repo>`. The local dir is a plain name under `~/Workspace`                         |
| `RC_REPOS`        | no       | Which repos get a Remote Control server, each `<repo>` or `<repo>:<agent>`. Default: every repo in `REPOS`, no agent                          |
| `RC_SPAWN`        | no       | `same-dir` (default): sessions work in the repo's checkout, with its dependencies and env files. `worktree`: each session gets a git worktree |
| `RC_CAPACITY`     | no       | The most sessions one repo's server runs at once. Unset leaves Claude Code's own default                                                      |

Every script on the box checks the inputs before it does anything and stops, naming the input, if one is missing or wrong.

## Order of operations

This is the order when I build a box for someone else. "Root" and "box user" are SSH sessions on the box: the operator opens them over public SSH with their key until the close.

| Step | Who and where                           | What                                                                                                                                                                           |
| ---- | --------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 1    | Operator, root                          | Clone this repo to `/opt/cloud-box`, write `box.env`, run `01-base.sh`. Public SSH is key-only from here, before anything of the owner's reaches the box                       |
| 2    | Operator, root, then owner              | `02-tailscale-lockdown.sh up`. The owner signs in to Tailscale and proves two routes in: their laptop to the box user over the tailnet, and root in the provider's web console |
| 3    | Owner, box user                         | Claude sign-in and GitHub sign-in                                                                                                                                              |
| 4    | Operator, box user                      | `03-repos.sh` clones the repos and installs their dependencies                                                                                                                 |
| 5    | Owner's laptop                          | `laptop/push.sh` copies the Claude Code config, the chosen connectors and the git identity. Then the copy lines for env files and folders with no remote                       |
| 6    | Owner, then operator, box user          | Connector sign-ins. Then the trust step for each repo                                                                                                                          |
| 7    | Operator, box user                      | `05-remote-control.sh` starts a Remote Control server per repo                                                                                                                 |
| 8    | Owner, phone                            | Try it out, then end each repo's startup session                                                                                                                               |
| 9    | Operator, root, with the owner's laptop | `02-tailscale-lockdown.sh close`. Public SSH closes. This is the last configuration step                                                                                       |
| 10   | Operator, root                          | `06-handover.sh` removes the operator's key. The operator disconnects and the owner repeats one short operation from the phone                                                 |

**Building your own box,** you are both roles and the order changes: run step 9 straight after step 2, then steps 3 to 8 over Tailscale (`ssh <box user>@<box name>`), and skip step 10. The two orders differ because of who can get back in. You are on your own tailnet, so if a connection drops after the close you open another. An operator building for someone else is not on the owner's tailnet, so after the close a dropped session is gone for good, and the rest of the call would move onto keyboard control of the owner's laptop. So for them the close comes last, and the base build has already made public SSH key-only before any of the owner's sign-ins arrive.

### 1. Base build (operator, root)

```bash
ssh root@<server ip>
apt-get update && apt-get install -y git
git clone https://github.com/dhpwd/cloud-box /opt/cloud-box
cp /opt/cloud-box/box.env.example /opt/cloud-box/box.env
nano /opt/cloud-box/box.env
/opt/cloud-box/scripts/01-base.sh
```

To build from a particular revision, `git -C /opt/cloud-box checkout <commit>` before running anything.

The checkout and `box.env` stay owned by root and not writable by the box user: root runs scripts from there later, and the agents' account must not be able to change what root runs. Every root script checks this and stops if it isn't so.

`01-base.sh` installs git, the build tools, the GitHub CLI, ufw (left off until the close) and unattended security upgrades, creates the box user and adds `OPERATOR_PUBKEY` to its `authorized_keys`, turns on lingering so the user's services survive logout, and makes public SSH key-only. It then installs, as the box user, Node (pinned, through nvm), pnpm, bun, uv, pre-commit and Claude Code (the native installer). It prints sshd's effective settings for root and the box user and stops if either still allows a password. It needs no terminal and is safe to run again.

### 2. Tailscale (operator, root – then the owner)

```bash
/opt/cloud-box/scripts/02-tailscale-lockdown.sh up
```

The owner opens the URL it prints and signs in to their Tailscale account, then installs Tailscale on the laptop under the same account. Two proofs, now, while public SSH is still there as a way back:

1. From the owner's laptop: `ssh <box user>@<box name>`, where the box name is the MagicDNS name the script printed. On a new tailnet Tailscale may print a link to approve in the browser first
2. The owner signs in as root in the provider's web console – see [Root on the box](#root-on-the-box) for the password

### 3. Claude and GitHub sign-ins (owner, box user)

Claude's sign-in asks for a code to be pasted back, so the owner does it in a box-user session opened on their own laptop, with the screen share paused:

```bash
ssh <box user>@<box name>
claude          # then /login, open the URL, sign in, paste the code back, then /exit
```

GitHub, in any box-user session:

```bash
gh auth login --hostname github.com --git-protocol https --web
```

The owner enters the code it prints at [github.com/login/device](https://github.com/login/device).

### 4. Repos (operator, box user)

```bash
/opt/cloud-box/scripts/03-repos.sh
```

It clones each repo in `REPOS` into `~/Workspace`, installs dependencies with the manager the lockfile names (bun, pnpm or npm, and `uv sync` where there is a `uv.lock`), installs each repo's pre-commit hooks, and lets a session's `git push` use the owner's GitHub sign-in. A repo with no lockfile it recognises gets a review line: confirm nothing needs installing, or install it by hand. If a clone or an install fails it carries on through the list, then stops naming what failed. Run it again once that's fixed: an existing clone is pulled fast-forward only, never overwritten.

**A repo that needs an env file before its install:** an install hook can succeed with the wrong defaults when the file is missing, so copy it in between two runs:

```bash
/opt/cloud-box/scripts/03-repos.sh --clone-only
# copy the env file with the file copy line in step 5
/opt/cloud-box/scripts/03-repos.sh
```

A repo's own tracked `.mcp.json` arrives with its clone. If it reads environment variables, the box needs them too.

### 5. Config, connectors and files (owner's laptop)

The laptop takes `push.sh` from the box, so it is always the revision the box is running. If the checkout isn't at `/opt/cloud-box`, set `BOX_REPO` to its path in front of `/bin/bash`:

```bash
( d=$(mktemp -d) || exit 1; trap 'rm -rf "$d"' EXIT; scp <box user>@<box name>:/opt/cloud-box/laptop/push.sh "$d/push.sh" && /bin/bash "$d/push.sh" <box user>@<box name> --connectors <name,name> )
```

Arguments after `<box user>@<box name>`:

- `--connectors <name,name>` – the user-scope connectors to send, by name. `--connectors none` sends none, and the box still lists the status of the claude.ai connectors. With neither, it lists the names and asks. Nothing is sent by default, because a laptop can hold another business's connectors
- `--replace` – replace a connector already registered on the box under the same name. Without it, an existing one is left as it is
- `--exclude <path under ~/.claude>` – leave out a file or folder, such as `skills/client-work` or `~/.claude/skills/client-work`. Repeat it for more. A path that names nothing under `~/.claude` stops the run before anything is sent

It copies from the laptop's `~/.claude/` into the box user's: `CLAUDE.md`, `settings.json`, `keybindings.json` and the `skills`, `agents`, `commands`, `rules`, `output-styles` and `hooks` folders, following symlinks. It overwrites files of the same name on the box and deletes nothing. It also sets the box's git identity from the laptop's, so a session can commit. Before anything leaves the laptop it lists what it will send, by name and with any symlink's target, and sends nothing on any answer but `yes`. It sends only what that list showed, even if a file is added while it waits. The connectors go to `scripts/04-connectors.sh` on the box, which registers them without printing a key, URL or command line. Afterwards it lists what it copied and names anything to fix by hand: files that mention `/Users/` or the laptop's home directory, imports and `~` paths that point at something that wasn't sent, plugins `settings.json` turns on, and servers registered for one project on the laptop.

It needs `ssh`, `git` and `python3` on the laptop. A Mac has `python3` once Apple's command line tools are installed (`xcode-select --install`).

**What is not copied:** the Claude sign-in, `~/.claude.json` (only the chosen connectors' definitions cross), session history and auto memory (`~/.claude/projects`), plugins, shell and Claude history, anything under `~/.ssh`, servers registered for one project, env files and folders with no git remote. Connectors added in claude.ai follow the Claude sign-in and need nothing copied.

**The two copy lines,** from the laptop, for env files and folders with no git remote. They are copied once, at setup:

```bash
scp <file on the laptop> <box user>@<box name>:Workspace/<repo>/<path in the repo>
scp -r <folder on the laptop> <box user>@<box name>:<where it goes, such as Workspace/>
```

### 6. Connector sign-ins and the trust step (box user)

`04-connectors.sh` ends by listing each connector's status and the sign-ins still needed. The owner makes those:

- A claude.ai connector: `claude mcp login "claude.ai <Name>" --no-browser`, then open the link it prints on any device
- Any other connector that needs a browser sign-in: run `claude`, then `/mcp`, choose it and follow the steps

Then the operator runs the trust step, once per repo in `RC_REPOS`, in a terminal as the box user. Under systemd a Remote Control server can't ask its first-run questions and exits instead, so they are answered here:

```bash
cd ~/Workspace/<repo>
claude remote-control --no-create-session-in-dir --spawn <RC_SPAWN, same-dir unless you set it>
```

Answer `y` to each question, wait until it says it is running, then press Ctrl+C. This is a normal step, not a repair.

### 7. Remote Control (operator, box user)

```bash
/opt/cloud-box/scripts/05-remote-control.sh
```

It installs a systemd user unit, `claude-rc@<repo>.service`, for each repo in `RC_REPOS` and starts it. Each server shows in the Claude apps and starts a session in its repo whenever one is opened there. Sessions follow `defaultMode` in the owner's `settings.json`, and a `<repo>:<agent>` entry has every session that server starts run as that agent. The script then waits and checks each server stayed up. If one didn't, it names the cause it can see: the trust step missed, Remote Control off for the owner's organisation, or the journal lines to read. Run again, it restarts only the servers whose settings changed, and says that their open sessions stop until next opened in the app.

### 8. Try it (owner, phone)

1. With the laptop shut, continue on the phone a session started in the desktop app
2. Start a new session from the phone and ask it to read a file that exists only on the box
3. Use each connector once from a session
4. End each repo's startup session in the app (see [Memory](#memory))

### 9. Close public SSH (operator, root, with the owner's laptop open)

```bash
/opt/cloud-box/scripts/02-tailscale-lockdown.sh close
```

It binds sshd to the Tailscale address, turns off root login and passwords for sshd, allows only `BOX_USER`, and sets the firewall to accept nothing from outside the tailnet. Before it changes anything it arms a revert: unless a second prompt confirms a fresh connection worked, the whole change is undone after 300 seconds. When it asks, the owner opens a new connection from their laptop (`ssh <box user>@<box name>`), and the operator answers `yes` only once that has worked. A `yes` that arrives after the 300 seconds is refused, because the revert has already reopened public SSH: run the close again.

### 10. Handover (operator, root)

Run it in the root session that ran the close: after the close root can't sign in over SSH, and the operator isn't on the tailnet.

```bash
/opt/cloud-box/scripts/06-handover.sh
```

It refuses until the close has been confirmed with no revert pending, and while sshd would still allow a root login or a password, naming the file responsible. Then it removes the operator's key from root and the box user, prints the fingerprints of the keys left (fingerprints only), and prints the box's final state: the Remote Control servers, the Tailscale name, the sshd settings and every firewall rule for IPv4 and IPv6. It leaves a marker so `01-base.sh` never adds the operator's key again, and sets up nothing for later access. The operator then closes every session, and the owner repeats one short operation from the phone to show the box works as delivered.

If the operator's root session was lost after the close, the owner runs it instead, as root over Tailscale SSH from their laptop: `ssh root@<box name>`.

## The owner's steps, in one list

- Before the call: order the server with the operator's key, sign up for Tailscale and install it on the laptop, check the Claude plan (and the Remote Control toggle on a Team or Enterprise plan), install the Claude app on the phone
- Step 2: sign in to Tailscale from the link, connect once from the laptop, set root's password and sign in to the provider's console as root
- Step 3: the Claude sign-in (screen share paused) and the GitHub device code
- Step 5: run `push.sh` on the laptop, or hand over keyboard control to run it, and answer `yes` to what it will send
- Step 6: each connector's sign-in
- Step 8: the four checks from the phone
- Step 9: a fresh connection from the laptop when the close asks for it
- Step 10: one short operation from the phone

## Sign-ins the owner makes themselves

Tailscale, Claude, GitHub and each connector. The operator never holds the owner's passwords, codes or tokens, and the box user has no password at all.

## Root on the box

The owner signs in as root in the provider's web console at step 2 and again for a repair, so they need root's password. Nothing here sets it, and the operator never holds it.

The simplest way to set one is from the owner's laptop over Tailscale SSH, with the screen share paused:

```bash
ssh root@<box name>     # Tailscale may ask for a browser approval first
passwd
```

From Netcup's help pages (read 25/11/2026: [accessing your server](https://www.netcup.com/en/helpcenter/documentation/server/accessing-server), [setting a new password](https://www.netcup.com/en/helpcenter/documentation/server/access), [media](https://www.netcup.com/en/helpcenter/documentation/server/media)): for a server delivered with its default image, the email titled "Ihr vServer bei netcup ist bereit gestellt." contains the root password, and the console is the "Screen" item in the Server Control Panel. The control panel can also set a new root password under Access ("Set Root Password"), but only with the server powered off, which stops any sessions running on it. After an image is installed from the control panel, it shows the new root password. Whether a root password is still set when the image is installed with an SSH key is not confirmed.

## Memory

Every Remote Control server opens one session in its repo each time it starts, including after a reboot or a restart, and open sessions are what use memory: each one is a full Claude Code process with its own copy of every stdio connector, many times the size of an idle server. Ten repos' startup sessions could take most of a 16GB box. So once the phone checks pass, end each repo's startup session in the app, and again after the box restarts. The server stays up and starts a new session whenever one is opened.

`RC_CAPACITY` caps how many sessions one repo's server runs at once. Change it in `box.env` and run `05-remote-control.sh` again, which restarts the servers.

## Adding a repo later

As root, add it to `REPOS` (and `RC_REPOS`, if that is set) in `/opt/cloud-box/box.env`. Then, as the box user: `03-repos.sh`, the trust step for the new repo, and `05-remote-control.sh`. The servers already running are left alone. For an owner who doesn't use a terminal, this is a job for a helper under keyboard control (see below).

## If a setup is interrupted

Every script is safe to run again and stops, naming the step to resume, when something it needs is missing.

- **After step 1:** public SSH is key-only, the operator's key is on the box user, and nothing of the owner's is on the box
- **After step 2:** Tailscale is up on the owner's tailnet and public SSH is still open, key-only. If the owner's laptop has connected over the tailnet, run the close before leaving, so nothing waits on a public port. The operator's key stays until the handover, whatever step the setup stops at
- **After step 3:** the owner's Claude and GitHub sign-ins are on the box. Close public SSH before leaving
- **After step 4:** the repos are cloned. A repo left at `--clone-only` has no dependencies yet: run `03-repos.sh` again once its env file is in place
- **After step 5:** the config, connectors and git identity are on the box. Running `push.sh` again overwrites files of the same name and leaves registered connectors alone
- **After steps 6 and 7:** any repo whose trust step was missed has no running server. `05-remote-control.sh` names it, and running it again after the trust step starts it
- **After step 8:** the box is in use, with public SSH still open. Run the close
- **After step 9, before step 10:** the box is closed but the operator's key is still on it. The owner runs `06-handover.sh` as root over Tailscale SSH

## Getting back in, and getting help

The owner reaches the box over Tailscale SSH from any laptop signed in to their Tailscale account: `ssh <box user>@<box name>`, and `ssh root@<box name>` after a browser approval. If Tailscale or SSH is the fault, root signs in through the provider's web console. A new or replaced laptop needs only Tailscale signed in, with no key file to carry across.

After the handover, someone helping the owner has no access of their own. The owner shares their screen on a call and hands over keyboard control, and the helper works from the owner's laptop over that route, or in the provider's console if Tailscale or SSH is the fault. The owner types no terminal commands.

**Granting sudo.** The box user has no password and isn't in the `sudo` group, so the agents can't give themselves admin rights. To grant it deliberately, as root: `passwd <box user>`, then `usermod -aG sudo <box user>`. Every session on the box runs as that account, so think before you do. `01-base.sh` refuses to run while the box user has sudo, so take it away again before re-running the base build.

**Tailscale SSH and root.** sshd's settings, including `PermitRootLogin no`, govern only sshd. Tailscale SSH is a separate listener that never reads them: its control is the tailnet's SSH policy. Under Tailscale's default policy the owner can reach root on their own machine after a browser approval, which is reused for a period ([Tailscale SSH docs](https://tailscale.com/docs/features/tailscale-ssh), read 24/11/2026).

## Scripts

| Script                                   | Runs as            | Needs first                                   |
| ---------------------------------------- | ------------------ | --------------------------------------------- |
| `scripts/01-base.sh`                     | root               | `box.env`                                     |
| `scripts/02-tailscale-lockdown.sh up`    | root               | –                                             |
| `scripts/03-repos.sh`                    | box user           | GitHub sign-in                                |
| `laptop/push.sh`                         | the owner's laptop | Tailscale on the laptop                       |
| `scripts/04-connectors.sh`               | box user           | run by `push.sh`                              |
| `scripts/05-remote-control.sh`           | box user           | Claude sign-in, the trust step                |
| `scripts/02-tailscale-lockdown.sh close` | root               | the owner's laptop connected over the tailnet |
| `scripts/06-handover.sh`                 | root               | a confirmed close                             |

`scripts/lib.sh` is sourced by the others: it reads and checks the inputs. `tests/run.sh` tests the checks, the laptop script and the key and lockdown handling without root, network or a server.

## Optional scripts

Not part of a standard setup.

- `optional/playwright-mcp.sh` – a browser for the agents: two Playwright MCP servers (`playwright`, with a persistent profile, and `playwright-isolated`) at a pinned version, on a display of their own. As root first (the system packages), then as the box user (the browser and the registrations):

  ```bash
  /opt/cloud-box/optional/playwright-mcp.sh     # as root
  /opt/cloud-box/optional/playwright-mcp.sh     # then as the box user
  ```

- `optional/terminal.sh` – the terminal route: mosh, tmux 3.7 with a session per repo, and the shell helpers. As root first (packages and the tmux build), then as the box user:

  ```bash
  /opt/cloud-box/optional/terminal.sh     # as root
  /opt/cloud-box/optional/terminal.sh     # then as the box user
  ```

  Its `killagents` helper stops every `claude` process, the Remote Control servers included, which systemd then restarts. `shell/` holds the laptop side: source `shell/laptop.zsh` from `~/.zshrc`, add `shell/gitconfig` as a global `include.path`, point `core.excludesFile` at `shell/gitignore` and symlink `shell/starship.toml` to `~/.config/starship.toml`. The helpers need `mosh`, `fzf`, `fd`, `bat`, `starship` and `pngpaste` from Homebrew
- `optional/supervisor.sh` – brings the Claude Code background-job supervisor back after a reboot, for `claude --bg` jobs. As the box user: `/opt/cloud-box/optional/supervisor.sh`

## Coming from the blog post

The post describes six scripts and the terminal route: mosh, tmux and Termius, with my agents and my connector set. That route is now in `optional/`, and the repo as the post describes it is at [cb2cd46](https://github.com/dhpwd/cloud-box/tree/cb2cd46).

## If you lock yourself out

`02-tailscale-lockdown.sh close` is the only step that can. It arms a revert before it changes anything: unless a second prompt confirms a fresh connection worked, the whole change is undone after 300 seconds, so a wrong rule costs a five-minute wait rather than a trip to the provider's remote console. If it does come to that, sign in there as root and run:

```bash
rm /etc/ssh/sshd_config.d/99-tailscale.conf
systemctl restart ssh
ufw disable
rm /etc/cloud-box/closed
```

The last line matters: without it, a later handover would pass its check on a box whose public SSH you have reopened by hand.

## Secrets

Nothing in this repo holds a secret value, and `box.env` holds none. Connector keys go from the laptop's `~/.claude.json` to the box's over SSH, in memory, and no script prints one.

## Licence

MIT.
