# DevBootstrapper specification

Status: draft; every captain question is answered, and the work-laptop investigation (section 18) is pending.
Implementation repository: `YThibos/DevBootstrapper` (currently empty).
This spec lives in the First Officer repository so a First Officer on any machine can read it, investigate the open points in section 18, and refine it.
Implementation starts only after the investigation findings are folded in and the captain signs off.

## 1. Goal

DevBootstrapper is a portable, self-updating developer toolkit: one repository that turns a Windows machine with WSL2 into the same development environment at home and at work.
It covers a Java developer who also does Angular front-end work, and it hosts agent tooling such as Claude Code and EDI (the successor of First Officer).
Prerequisites stay minimal, and after the one-time install everything happens inside WezTerm.

## 2. Scope

In scope for v1:

- Windows 10 or 11 as the host, with WSL2 running the latest stable Ubuntu release.
- WezTerm nightly, from the portable zip, as the terminal.
- A structured, modular bash setup under `~/development/bash/`.
- Installing and updating every listed tool, plus WezTerm itself.
- Home and work profiles, including a corporate proxy.
- Default Claude Code user settings.

Out of scope for v1:

- macOS, and Linux distributions other than Debian and Ubuntu.
- The Windows-native side (Git Bash for Windows, PowerShell, Command Prompt), planned as a later phase under `C:\development\` (section 15).
- Kubernetes tooling.
- Installing IDEs or Docker Desktop.
- Cloning First Officer or EDI.
- Automatic cleanup of `tmp/`.

## 3. Prerequisites

- Windows 10 or 11 on which the user may run PowerShell scripts.
- WSL2 with an Ubuntu distribution installed and its Linux user created.
- Docker Desktop with WSL integration enabled for that distribution (optional, but needed for the `docker` command).
- Network access to GitHub and the tool download hosts, either directly or through the Windows proxy configuration.

The installer detects a missing WSL or Ubuntu and prints the exact command to install the newest Ubuntu release that `wsl --list --online` offers.
It does not install WSL or Ubuntu itself, because that needs administrator rights and a reboot.

## 4. Architecture

Three layers, each with a single entry point.

| Layer | Location | Entry point | Runs |
|---|---|---|---|
| Windows host | `C:\development\tools\` | `windows/install.ps1`, then the WezTerm launcher | Install once; the launcher runs every time WezTerm starts |
| WezTerm config | `~/development/config/wezterm/` | A stub `wezterm.lua` next to `wezterm.exe` that loads the repository config | Every WezTerm start, with hot reload |
| WSL shell | `~/development/` | `bash/bootstrap.sh`, sourced from `~/.bashrc` | Every shell |

Two jobs are kept strictly apart:

- Shell setup (`bash/bootstrap.sh`) is sourced by every shell.
  It must be fast, never touches the network and never asks for `sudo`.
- Install and update (`devup`) is idempotent and runs explicitly or once per day.
  A first install and a daily update are the same code path.

## 5. Dev home layout

The dev home is `~/development` on the WSL ext4 filesystem, never under `/mnt/c`, because cross-filesystem I/O is slow.
The DevBootstrapper repository is cloned directly as the dev home.
On Windows, `C:\development\` is the Windows-side dev home.
In v1 the toolkit uses only `C:\development\tools\wezterm\` and `C:\development\tools\launcher\` there; the rest is reserved for the later Windows-native phase.

```
~/development/
├── bash/
│   ├── bootstrap.sh        # sole entry point, sources the rest in an explicit order
│   ├── env.sh              # environment layer: DEV_HOME, PATH, XDG, tool homes, mise shims
│   ├── aliases.sh
│   ├── functions.sh
│   ├── completions.sh
│   ├── prompt.sh
│   ├── tools/              # one small init file per tool: mise, git, java, node, docker, fzf, zoxide
│   └── local.sh            # gitignored, per-machine shell overrides
├── install/
│   ├── devup.sh            # install and update, idempotent
│   ├── doctor.sh           # health report
│   ├── lib/                # shared helpers for the install scripts
│   └── apt-packages.txt
├── config/
│   ├── mise/config.toml    # the global tool manifest
│   ├── wezterm/wezterm.lua
│   ├── git/                # gitconfig, global ignore, attributes
│   ├── maven/settings.xml  # credentials only through environment variables
│   ├── npm/npmrc           # registry and cache settings, no tokens
│   ├── tmux/tmux.conf
│   ├── starship.toml
│   └── claude/             # settings.json and CLAUDE.md (section 14)
├── windows/
│   ├── install.ps1         # one-time Windows installer
│   ├── launcher.ps1        # WezTerm updater and launcher
│   └── wezterm-stub.lua    # copied next to wezterm.exe
├── sources/
│   ├── home/               # home project checkouts, always the home git identity
│   └── work/               # work project checkouts, always the work git identity
├── tools/                  # every mise-managed tool, plus tools/cache/ for all caches
├── tmp/                    # empty scratch directory, no automatic cleanup
├── .local/                 # gitignored machine settings: profile, proxy, git identities
├── .local.example/         # tracked templates for .local/
├── .secrets                # gitignored credentials, chmod 600
├── .secrets.example        # tracked list of expected keys, no values
├── .gitignore
├── .gitattributes
├── README.md
└── SPEC.md                 # this spec, copied in once approved
```

## 6. Version control model

- `.gitignore` is an allow-list: it starts with `/*` and re-includes only `bash/`, `install/`, `config/`, `windows/`, the dotfile templates and the top-level docs.
  `sources/`, `tools/`, `tmp/`, `.local/` and `.secrets` therefore cannot be committed by accident, even if a rule is forgotten.
- `tmp/` exists through a tracked `tmp/.gitkeep`, and its contents are ignored.
- `sources/home/` and `sources/work/` exist through tracked `.gitkeep` files, and the checkouts inside them are ignored.
- `.gitattributes` forces LF line endings for `*.sh`, `*.lua`, `*.toml` and configuration files, and CRLF for `*.ps1` and `*.cmd`.
- No tracked file may contain an employer name, internal host, proxy address, personal email address or credential.
  The repository is treated as public, so everything machine- or employer-specific lives in `.local/` or `.secrets`.

## 7. Install flow

### 7.1 Windows installer

The user runs one PowerShell line that downloads and runs `windows/install.ps1` from the repository's default branch.
The installer:

1. Detects WSL2 and the installed Ubuntu distribution, and asks which distribution to use if there are several.
   If WSL or Ubuntu is missing, it prints the install command for the newest Ubuntu release and stops.
2. Optionally writes or merges `%USERPROFILE%\.wslconfig` (opt-in prompt): mirrored networking, `autoProxy`, `dnsTunneling` and a memory cap.
3. Downloads the WezTerm nightly portable zip, verifies its checksum when one is published, and extracts it into `C:\development\tools\wezterm\`.
4. Copies `wezterm-stub.lua` next to `wezterm.exe` as `wezterm.lua`, and writes a small local file with the distribution name and Linux home path.
5. Copies `launcher.ps1` into `C:\development\tools\launcher\` and creates a Start-menu shortcut that runs it with a hidden window.
6. Runs the WSL first install: `git clone` of the repository into `~/development`, then `install/devup.sh --first-run`.
7. Restarts WSL if `/etc/wsl.conf` changed, then starts WezTerm through the launcher.

### 7.2 WSL first run

`devup --first-run` is interactive once:

1. Asks for the machine profile (`home` on the desktop PC, `work` on the work laptop) and writes `.local/profile.env`.
2. Asks for the home and work git identities, writes them to `.local/`, and selects the profile's identity as this machine's default.
3. Detects the proxy from the environment WSL inherited from Windows, asks to confirm or enter it, and records it in `.local/profile.env`.
4. Creates `.secrets` from `.secrets.example` with mode 600.
5. Writes `/etc/wsl.conf` (`systemd=true`, `appendWindowsPath=false`) with `sudo`.
6. Adds the bootstrap line to `~/.bashrc` (section 8), then runs the normal update path (section 11).

The bootstrap line goes above Ubuntu's default "return if not interactive" guard, so the environment layer also reaches non-interactive shells.

## 8. Shell layer

`~/.bashrc` gains exactly one line, near the top: `[ -f "$HOME/development/bash/bootstrap.sh" ] && . "$HOME/development/bash/bootstrap.sh"`.

`bootstrap.sh` does three things:

1. Always sources `env.sh`, `.local/profile.env` and `.secrets`.
   This sets `DEV_HOME`, PATH with mise shims, `XDG_CACHE_HOME=$DEV_HOME/tools/cache`, the `MISE_*` directories, the proxy variables and `BROWSER=wslview`.
2. Returns immediately if the shell is not interactive.
3. In interactive shells, sources an explicit, ordered list: `tools/*.sh` (including full `mise activate bash`), `aliases.sh`, `functions.sh`, `completions.sh` and `prompt.sh`, then `local.sh` last.

Requirements:

- Interactive startup stays under 200 ms, measured with `time bash -i -c exit`.
- No network access, no `sudo` and no prompts.
- Programs started without an interactive shell must see the same tools and the same git identity: EDI and Claude Code workers in tmux, git hooks, and IDE integrations.
  For that reason, configurations that other programs read live at the tools' default locations as symlinks into the repository (section 10).
  Environment variables are used only where nothing else reads the setting.
- A missing optional tool never breaks shell startup.
  Each `tools/*.sh` file checks for its tool and skips silently when it is absent.
- When the last successful update is older than one day, an interactive shell prints a one-line reminder to run `devup`.
  This covers terminals other than WezTerm.

## 9. Tool catalogue

Source rule: use mise when it offers a prebuilt binary; otherwise use apt; otherwise use the tool's own default platform.
A mise entry that only compiles from source through an asdf plugin counts as "not available in mise".
That is why git and tmux come from apt.

| Tool | Source | Version policy |
|---|---|---|
| Java JDK (8, 11, 17, 21, 25) | mise, Eclipse Temurin (OpenJDK builds) | Every LTS that is still supported, latest patch; default 25 |
| Maven 3 and Maven 4 | mise | Both installed; default is the 3.10 line (currently 3.10.0) until the captain says otherwise; switch with `mvnuse` (section 9.1) |
| Maven daemon (mvnd) | mise | Latest |
| Gradle | mise | Latest |
| Node.js and npm | mise | Current LTS; npm ships with Node |
| Angular CLI | mise, `npm:@angular/cli` | Latest, as a convenience; projects use their own local version through `npx` |
| Python | mise | Latest stable |
| uv | mise | Latest |
| Claude Code | mise (registry entry if present, else `npm:@anthropic-ai/claude-code`) | Latest |
| gh, jq, yq, ripgrep, fd, fzf, bat, eza, zoxide, delta, lazygit, lazydocker, starship, xh, shellcheck, shfmt | mise | Latest |
| git | apt, from the `git-core` PPA when it publishes for the installed Ubuntu release, otherwise the distribution package | Latest stable |
| tmux | apt | Distribution version |
| Base packages (curl, wget, zip, unzip, ca-certificates, gnupg, build-essential, bash-completion, wslu) | apt | Distribution version |
| docker CLI and compose | Docker Desktop WSL integration | Managed by Docker Desktop; `doctor` only checks it |
| WezTerm | Nightly portable zip, through the launcher | Latest nightly |

`wslu` provides `wslview`, so browser-based logins (`gh auth login`, Claude Code) open the Windows browser.
Projects pin their own versions through a project `.mise.toml` or `.java-version`, which mise honours automatically.

### 9.1 Switching the default version

The captain wants a quick command to switch the system-wide default version of a tool, starting with Maven.
"System-wide" means the whole WSL2 distribution in v1, and the Windows machine itself once the Windows-native phase exists.

- `use-version <tool> <version>` sets the default version of a mise-managed tool for this machine.
  `mvnuse <version>` and `jdkuse <version>` are shortcuts for Maven and Java.
- Without a version argument, the command lists the installed versions and marks the current default.
- The switch is machine-local and stored under `.local/`, so it never edits the tracked manifest in `config/mise/config.toml` and never changes other machines.
- It takes effect for new shells and for non-interactive callers, because mise resolves the default through its shims.
  The current shell picks it up immediately as well.
- A project's own `.mise.toml` or `.java-version` still wins inside that project.
- The Windows-native phase must provide the same commands with the same names for PowerShell and Git Bash.

## 10. Configuration ownership

| Tool | Repository file | How it is applied |
|---|---|---|
| mise | `config/mise/config.toml` | `MISE_GLOBAL_CONFIG_FILE`, plus a symlink at `~/.config/mise/config.toml` for non-interactive callers |
| git | `config/git/gitconfig` | Symlink at `~/.gitconfig`; first includes this machine's default identity from `.local/`, then `includeIf "gitdir:~/development/sources/work/"` and `.../home/` override it |
| Maven | `config/maven/settings.xml` | Symlink at `~/.m2/settings.xml`; local repository at `tools/cache/m2`; proxy and mirrors from environment variables |
| npm | `config/npm/npmrc` | Symlink at `~/.npmrc`; cache at `tools/cache/npm`; tokens through `${ENV}` references to `.secrets` |
| tmux | `config/tmux/tmux.conf` | Symlink at `~/.config/tmux/tmux.conf` |
| starship | `config/starship.toml` | `STARSHIP_CONFIG` |
| WezTerm | `config/wezterm/wezterm.lua` | Loaded by the Windows-side stub over `\\wsl.localhost\<distro>\...`, with a minimal built-in fallback when WSL is unreachable |
| Claude Code | `config/claude/settings.json`, `config/claude/CLAUDE.md` | Symlinks into `~/.claude/` (section 14) |

`devup` owns every symlink.
It replaces an existing real file only after backing it up to `tmp/backup-<date>/`.
Repositories outside `sources/home/` and `sources/work/`, including the dev home itself, use the machine's profile identity: work on the work laptop, home on the desktop PC.

## 11. Update model

### 11.1 WezTerm

The Start-menu shortcut runs `launcher.ps1`, which:

1. At most once per day, compares the nightly zip's published timestamp or ETag with the last installed one.
2. When newer, downloads it to a staging directory and verifies it.
3. Only if no WezTerm process is running, swaps the staging directory in and keeps the previous version for one rollback.
4. Restores the stub `wezterm.lua` and the local file, then starts `wezterm-gui.exe`.

Downloads use the Windows system proxy with default credentials.

### 11.2 Everything else: `devup`

`devup` runs these steps in order, each idempotent and individually skippable with a flag:

1. `git pull --ff-only` of the dev home.
   If the working tree is dirty or has diverged, it skips the pull and reports instead of stashing or merging.
2. Syncs `windows/` assets to the Windows tools directory through `/mnt/c`.
3. `sudo apt-get update` and `upgrade`, with the user typing the password.
4. `mise self-update`, `mise upgrade` within the version pins, `mise install` for new entries, then `mise prune` of versions no longer referenced.
5. Ensures the symlinks from section 10.
6. Runs `doctor` and prints a short report: tool versions, failed steps, Docker availability and proxy reachability.
7. Writes the last-update stamp to `tools/state/last-update`.

### 11.3 Daily trigger

On the first WezTerm start of a day, `wezterm.lua` (in its `gui-startup` event) reads the stamp file and opens one extra tab running `devup --daily`.
The user sees the output there and types the `sudo` password.
Other terminals get only the reminder from section 8.

### 11.4 Version pinning

Runtimes keep their major or LTS line fixed (Java per LTS, Node `lts`, Maven 3.10 and 4), so updates stay within that line.
CLI tools follow `latest`.
Moving a runtime to a new major version is a deliberate edit of `config/mise/config.toml`.

## 12. Profiles, proxy and certificates

`.local/profile.env` holds `DEV_PROFILE=home|work` plus machine settings: proxy URL, `NO_PROXY`, registry mirror URLs and the path to the corporate root certificate.
Every tool reads its proxy and certificate settings from that one place:

- Environment: `HTTP_PROXY`, `HTTPS_PROXY`, `NO_PROXY` and their lowercase forms, for curl, mise, git, npm, uv and pip.
- apt: a drop-in under `/etc/apt/apt.conf.d/` rendered by `devup`.
- Maven: `<proxies>` and `<mirrors>` in `settings.xml`, interpolated from environment variables.
- Java: `JAVA_TOOL_OPTIONS` proxy properties, and the corporate root certificate imported into each installed JDK's trust store by `devup`.
- Node: `NODE_EXTRA_CA_CERTS`.
- Python: `REQUESTS_CA_BUNDLE` and `SSL_CERT_FILE`.
- System: the certificate added to the Ubuntu trust store with `update-ca-certificates`.

With an empty proxy and no certificate configured, all of this is a no-op, which is the home profile.
How the work proxy actually behaves (authentication, PAC file, TLS inspection) is an investigation item (section 18).

## 13. Secrets

- `.secrets` sits at the dev home root, is gitignored and is created with mode 600.
- Its format is `KEY=value` lines, loaded with `set -a`, so the same file also works as a Docker `--env-file`.
- `bootstrap.sh` warns, without printing values, when the file mode is wider than 600.
- `.secrets.example` is tracked and lists every expected key with a comment and no value.
- Configuration files reference secrets only through environment variables, never by value.
- Encryption (for example sops with age, or a password-manager CLI) is a possible later step, not v1.

## 14. Claude Code

- Claude Code comes from mise (section 9), so its updates come from `devup` rather than its own updater.
- `config/claude/settings.json` and `config/claude/CLAUDE.md` hold the captain's cross-project preferences.
  `devup` symlinks them into `~/.claude/`.
- Changes Claude Code writes to `settings.json` therefore show up as a git diff in the dev home, to commit or discard deliberately.
- Credentials, history and project state stay in `~/.claude/` and are never tracked.
- The initial contents of these two files come from the work-laptop investigation (section 18), with secrets and internal hosts removed.

## 15. Portability

- The shell layer (`bash/`) and most of `config/` are plain bash and standard configuration files.
  They work unchanged in WSL under any terminal, such as Windows Terminal; only the daily update tab is WezTerm-specific, and the shell reminder covers that case.
- They also work on native Ubuntu or Debian, including over SSH.
  Windows-only pieces (`wslview`, `/mnt/c` sync, `wsl.conf`) are guarded by WSL detection.
- `devup` is Debian- and Ubuntu-specific because of apt.
  Another Linux distribution would need only a package-manager adapter, because mise itself is distribution-independent.
- The Windows-native side (Git Bash for Windows, PowerShell and Command Prompt) is a different environment: Windows paths, no apt, Windows-native binaries and a different home.
  The WSL installer cannot be reused there.
  It is planned as a later phase with its own install path under `C:\development\`.
  Git Bash can still share `aliases.sh`, `functions.sh`, `prompt.sh` and the git configuration, so v1 must keep those files free of WSL-only assumptions.

## 16. Footprint outside the dev home

Everything outside `~/development`, listed so it can be audited and removed:

- WSL: one line in `~/.bashrc`; the symlinks from section 10; `/etc/wsl.conf`; the apt drop-ins for the proxy and the git PPA; the corporate certificate in the system trust store; and the apt packages.
- Windows: `C:\development\tools\wezterm\` and `C:\development\tools\launcher\`, the Start-menu shortcut and, opt-in, `%USERPROFILE%\.wslconfig`.

`README.md` documents uninstall: remove the `~/.bashrc` line, run `devup --unlink` to remove the symlinks, delete `~/development`, and delete the Windows tools directory and shortcut.

## 17. Acceptance criteria

On a fresh Windows machine with WSL2 and Ubuntu:

1. One PowerShell command, plus answering the first-run prompts, ends with WezTerm open in an Ubuntu shell at `~/development`.
2. `java -version` reports 25, `mise ls java` lists every supported LTS, and `mvn`, `node`, `npm`, `ng`, `python`, `uv`, `claude`, `gh`, `tmux` and `docker` all resolve.
3. Every mise-managed tool, and every cache, lives under `~/development/tools/`.
4. A second `devup` run changes nothing and reports success.
5. `git config user.email` differs between a repository in `sources/home/` and one in `sources/work/`, also from a non-interactive shell.
6. After `.secrets` is filled in and files are added to `tmp/`, `git status` in the dev home stays clean.
7. Interactive shell startup stays under 200 ms.
8. The daily update tab opens at most once per day.
9. The launcher installs a newer WezTerm nightly on the next start after one is published.
10. The work profile installs and updates successfully behind the corporate proxy.
11. Every shell script passes `shellcheck`.
12. `mvn -v` reports 3.10; after `mvnuse 4`, both a new interactive shell and a non-interactive shell report Maven 4, and `mvnuse 3.10` switches back, with no change to tracked files.
13. Outside `sources/`, `git config user.email` returns the work identity on a machine with the work profile and the home identity on one with the home profile.

## 18. Work-laptop investigation brief

The captain's work laptop has a First Officer checkout and a repository called "Justice onboarding".
That repository was an earlier attempt at this toolkit: a one-time hook setup to get any dev work going, which turned out not to be flexible enough.
A First Officer on that laptop should run a scout covering the points below.
It writes findings to its private report, and feeds back into this spec only generic facts, never internal hostnames, employer details or credentials.

1. Justice onboarding: what it sets up, how it is triggered, which parts are worth reusing, and exactly where it proved too rigid.
2. Corporate proxy: whether it needs authentication (and which kind), whether it uses a PAC file, whether TLS inspection with a corporate root certificate is in place, and whether WSL's `autoProxy` passes it through.
3. Package registries: whether work uses Maven and npm mirrors (Artifactory, Nexus or similar), how authentication is configured today, and whether public registries are blocked.
4. Restrictions on the laptop: PowerShell execution policy, AppLocker or similar, administrator rights, whether WSL and Ubuntu may be installed, and which Ubuntu version is allowed.
5. Current Claude Code user settings and user-level `CLAUDE.md`, as a candidate for `config/claude/`.
6. Java, Maven, Node and Angular versions used across current work projects, to confirm the version policy in section 9, including whether the work builds run on Maven 3.10 and Maven 4.
7. Current git, Maven and npm user configuration, with credentials replaced by placeholders.
8. Which IDE is used and how it reaches the code: IntelliJ on Windows against WSL sources, JetBrains Gateway, VS Code Remote WSL, or something else.
9. What EDI needs from its host beyond tmux, gh and git.
10. Which tools are installed on the laptop today (winget, Chocolatey, Scoop or manual), to catch anything missing from section 9.
11. Whether `C:\development\` exists and can be written without administrator rights, and what it currently contains.

## 19. Open questions

None for the captain at this point.
The remaining unknowns are the work-laptop investigation items in section 18; any question they raise is added here.

## 20. Decisions recorded

- Windows is the only host platform for v1, with WSL2 and Ubuntu assumed.
- Ubuntu is the latest stable release available.
  The captain prefers bleeding-edge releases.
  The installer detects and explains a missing WSL or Ubuntu, but does not install them.
- WezTerm runs from the nightly portable zip and is updated by a custom launcher, not Scoop.
- Windows-side files live in `C:\development\tools\`.
  The Windows-native side (Git Bash, PowerShell, Command Prompt) is a later phase, and Git Bash lite mode is not part of v1.
- The DevBootstrapper repository is treated as public.
- The dev home is `~/development`, which is the repository itself, using an allow-list `.gitignore`.
- All mise-managed tools live in `~/development/tools/`, and all caches in `~/development/tools/cache/`.
- `tmp/` exists, is never committed and is never cleaned automatically.
- `.secrets` lives at the dev home root and is never committed.
- The bash setup is modular under `bash/`, entered only through `bootstrap.sh`.
- Shell setup and install/update are separate (`bootstrap.sh` versus `devup`).
- Configurations are applied through environment variables or symlinks, with the full footprint listed in section 16.
- Project checkouts go in `~/development/sources/home/` and `~/development/sources/work/`, and the folder decides the git identity.
  Everywhere else, the machine's profile decides: work on the work laptop, home on the desktop PC.
- Java comes from Eclipse Temurin: every supported LTS (8, 11, 17, 21, 25) on every machine, with JDK 25 as the default.
- Maven 3 and Maven 4 are both installed, with the 3.10 line (currently 3.10.0) as the default until the captain says otherwise.
- Switching the default version is one quick command per machine (`mvnuse`, `jdkuse`, `use-version`), with Windows-side equivalents in the later phase.
- npm is the only Node package manager, at home and at work.
- The work profile has a corporate proxy.
- The daily update asks for the `sudo` password in its own tab; there is no passwordless `sudo` rule.
- Default Claude Code user settings are tracked in `config/claude/`.
- First Officer and EDI are not cloned by the toolkit, but their prerequisites (tmux, gh, git) are installed.
- Managing `.wslconfig` is an opt-in installer step.
- There is no Kubernetes tooling.
- All suggested CLI tools from section 9 are included.
