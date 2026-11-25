# Claude profiles

One machine can run several Claude Code subscriptions side by side. Each
subscription is a profile with its own sign-in. All profiles share one set of
settings, skills, agents, plugins, history, and sessions. A small set of scripts
selects the profile, labels it, and applies the device policy to it.

## Terms

| Term | Meaning |
| --- | --- |
| profile | One Claude Code sign-in with its own folder and its own launcher. |
| default profile | The profile that does not set `CLAUDE_CONFIG_DIR`. Its folder is `~/.claude`. Its state file is `~/.claude.json`. |
| named profile | Every other profile. Its folder is `~/.claude-<name>`. Its state file is `~/.claude-<name>/.claude.json`. |
| launcher | The shell function that starts Claude Code for one profile. Its name is `claude` plus one letter. |
| state file | The `.claude.json` file of a profile. It holds the sign-in record and options that belong to one profile. |
| device policy | The machine-wide policy that Claude Code reads from `/Library/Application Support/ClaudeCode`. |

## Parts on the Mac

| Part | Location | What it does |
| --- | --- | --- |
| Launchers | `~/.zshrc`, between `# >>> claude accounts >>>` and `# <<< claude accounts <<<` | One launcher per profile. A guard function replaces the bare `claude` command. |
| Profile mapping | `~/.zshenv` | Sets `CLAUDE_CONFIG_DIR` from `CLAUDE_PROFILE` when `CLAUDE_CONFIG_DIR` is empty. |
| Shared settings | `~/.claude/settings.json` | One settings file for every profile. It sets the status line, the hooks, and `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB`. |
| Status line | `~/.local/bin/claude-statusline.sh` | Shows the profile label at the start of row one. |
| Editor launcher | `~/.local/bin/claude-ide` | Reads `CLAUDE_ACCOUNT` and runs the matching launcher. Any other value runs the default launcher. |
| Workspace launcher | `~/.local/bin/tdev` | Starts a workspace in a folder. One flag per named profile selects the launcher. No flag selects the default launcher. |
| Tab state | `~/.local/bin/claude-tab-state` | Records the profile of each iTerm2 tab. Its `ACCOUNTS` table maps a profile name to its launcher letter. |
| Cache refresh | `~/.local/bin/claude-refresh-cache.sh` and a LaunchAgent in `~/Library/LaunchAgents` | Refreshes the extra-model list of every profile each Monday at 10:00. |
| Device policy | `/Library/Application Support/ClaudeCode` | Applies one policy to every session, with extra limits for chosen sign-ins. |
| Account limits | `~/.config/claude-policy/account-limits.json` | A machine-local file. It denies models to chosen sign-ins. It must not be committed. |

## Parts in this repository

| Part | Location | What it does |
| --- | --- | --- |
| Policy builder | `.agents/claude/device/build.py` | Builds the shared payload and one payload for each limited sign-in. |
| Policy helper | `.agents/claude/device/policy-helper.sh` | Chooses the payload for the sign-in of the starting profile. |
| Policy installer | `.agents/claude/install-device-policy.sh` | Builds, checks, and copies the policy to the machine-level folder. It needs `sudo`. |
| Generic status line | `.agents/claude/statusline.sh` | Takes the label from `CLAUDE_PROFILE`, or from the name of the profile folder. |
| Phone-link installer | `.agents/iterm/phone/install.py` | Adds one `PermissionRequest` hook to the user settings of each profile folder that exists. |
| Server launchers | `.agents/iterm/server/launchers.bash` | The launcher block for the Linux server. |
| Server setup | `.agents/iterm/server/setup-server.sh` | Writes the launcher block into the server user's `~/.bashrc`. Creates each profile folder with its own files. |
| Review-pane command | `.agents/iterm/bin/pane-run` | On the server, finds the live session in the session registry of each profile folder. |

## How a session selects its profile

1. You type a launcher. The launcher sets `CLAUDE_PROFILE` to the profile name.
2. A named launcher also sets `CLAUDE_CONFIG_DIR` to `~/.claude-<name>`. The default launcher removes `CLAUDE_CONFIG_DIR` instead.
3. Claude Code reads the folder that `CLAUDE_CONFIG_DIR` names. Without it, Claude Code reads `~/.claude` and `~/.claude.json`.
4. Claude Code reads the sign-in from the Keychain entry of that folder. See Credentials.
5. `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB` removes `CLAUDE_CONFIG_DIR` from every command that Claude runs. `CLAUDE_PROFILE` stays.
6. `~/.zshenv` sets `CLAUDE_CONFIG_DIR` again when `CLAUDE_PROFILE` names a named profile. A nested `claude -p` therefore runs on the same profile.

The default launcher must not set `CLAUDE_CONFIG_DIR`. If you set it to `~/.claude`,
Claude Code looks for `~/.claude/.claude.json`. That file does not exist, and the
profile starts signed out.

A bare `claude` command prints the list of launchers and returns 1. It passes
`--version`, `-v`, `--help`, `-h`, `update`, `install`, and `doctor` to Claude
Code. Run `command claude` to start the default profile without a launcher.

## What profiles share

A named profile folder links nine items to the default profile folder:
`agents`, `file-history`, `history.jsonl`, `output-styles`, `plugins`, `projects`,
`sessions`, `settings.json`, and `skills`.

| Item | Between profiles | Effect |
| --- | --- | --- |
| `settings.json` | Shared | A change to the hooks, the environment, or the status line applies to every profile. |
| `skills`, `agents`, `plugins`, `output-styles` | Shared | Every profile has the same skills, agents, plugins, and output styles. |
| `history.jsonl`, `file-history`, `projects` | Shared | Every profile writes its transcripts and history to one place. |
| `sessions` | Shared | One session registry covers every profile. |
| State file | Separate | Each profile has its own sign-in record and options. |
| Keychain entry | Separate | Each profile has its own login. |
| `session-env`, `shell-snapshots`, `paste-cache`, `plans`, `jobs`, `daemon`, `state`, `backups`, `cache`, `ide` | Separate | Claude Code creates these runtime folders in a profile folder when it needs them. A profile does not read another profile's copy. |

To give one profile a different setting, add `--settings <file>` to its launcher.
The shared `settings.json` stays unchanged. A launcher may also unset
environment variables with `env -u`.

## Credentials

Claude Code keeps each login in the macOS Keychain. The default profile uses the
entry `Claude Code-credentials`. A named profile uses
`Claude Code-credentials-<suffix>`. The suffix is the first eight hexadecimal
digits of the SHA-256 hash of the profile folder path. The path has no trailing
newline.

Compute a suffix:

```sh
printf '%s' "$HOME/.claude-<name>" | shasum -a 256 | cut -c1-8
```

List the entries. The command prints entry names only and no secret:

```sh
security dump-keychain | rg -o '"svce"<blob>="Claude Code[^"]*"'
```

## Device policy

`managed-settings.json` in `/Library/Application Support/ClaudeCode` names
`policy-helper.sh`. Claude Code runs the helper at start and every 3,600,000 ms
(one hour). The helper has a limit of 5000 ms. It prints one JSON envelope with
`appendSystemPrompt` and `managedSettings`.

The helper chooses the payload in this order:

1. It finds the profile folder. It uses `CLAUDE_CONFIG_DIR`. If that is empty, it maps `CLAUDE_PROFILE` to `~/.claude-<name>` when the name belongs to a named profile. Otherwise it uses the home folder.
2. It reads `oauthAccount.emailAddress` from the state file in that folder, with `plutil`.
3. If `accounts/<email>.json` exists, the helper prints that file. Otherwise it prints `policy.json`.

A profile with no sign-in gets `policy.json`. The limit therefore follows the
signed-in account. It does not follow the folder.

### Limit a sign-in

Add an entry to the account-limits file. Only `deniedModels` is accepted.

```json
{"person@example.com": {"deniedModels": ["fable"]}}
```

The operator must run the installer in a terminal that can ask for `sudo`.
An agent must not run it.

```sh
bash .agents/claude/install-device-policy.sh
```

The installer builds the payloads in a staging folder. It proves that every
payload is a valid envelope. Then it copies them to the machine-level folder and
replaces the whole `accounts/` folder. To lift a limit, delete the entry and run
the installer again. To remove the device policy, run
`sudo rm -rf "/Library/Application Support/ClaudeCode"`.

A limit holds against normal use only. A person who can edit a state file can
change the email that the helper reads. A sign-in after a session starts takes
effect at the next hourly refresh.

## Weekly cache refresh

The shared settings set `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`. That flag also
stops the fetch of the extra-model list. A LaunchAgent runs
`claude-refresh-cache.sh` every Monday at 10:00. The script:

1. Copies `settings.json` to a temporary file.
2. Removes the flag from `settings.json`.
3. Starts each profile once with `claude -p "hi"`, with the flag unset.
4. Restores `settings.json` from the copy. A trap runs the restore on exit, on interrupt, and on termination.
5. Writes the extra models of each profile to `~/.claude/cache-refresh.log`.

For a few seconds, any session that starts in any profile also runs without the
flag, because `settings.json` is shared. The script does not refresh feature
flags. The script lists the profiles by name.

## Server

The server launcher block makes every server profile a named profile: each
launcher sets `CLAUDE_CONFIG_DIR`. The `~/.claude` folder of the server user
keeps the login that was already there, and no launcher uses it. The server
policy helper, the server status line, and `pane-run` list the profile folders
by name.

`setup-server.sh` writes files into each server profile folder: the settings,
the output style, the instructions file, and the skills. The server profile
folders are not linked to one shared folder.

## Places that list profiles

The scripts do not read one list. Each file below holds its own list. Edit every
file when you add or remove a profile.

| File | List |
| --- | --- |
| `~/.zshrc` | The launchers, the aliases, and the list that the guard prints. |
| `~/.zshenv` | The `case` list of named profile names for the `CLAUDE_PROFILE` mapping. |
| `~/.local/bin/claude-statusline.sh` | The `case` that maps a folder path to a label and a colour. |
| `~/.local/bin/claude-tab-state` | The `ACCOUNTS` table. |
| `~/.local/bin/claude-ide` | The `case` on `CLAUDE_ACCOUNT`. |
| `~/.local/bin/tdev` | One flag for each profile. |
| `~/.local/bin/claude-refresh-cache.sh` | The profile folders that it starts. |
| `.agents/claude/device/policy-helper.sh` | The `case` list of named profile names. The installer copies it to the machine-level folder. |
| `.agents/iterm/phone/install.py` | The `ACCOUNTS` tuple of profile folders. |
| `.agents/iterm/server/launchers.bash`, `.agents/iterm/server/policy-helper.sh`, `.agents/iterm/server/claude-statusline.sh`, `.agents/iterm/bin/pane-run` | The server profiles. |

## Add a named profile

1. Choose a name and a launcher letter that no launcher uses.
2. Create the folder: `mkdir ~/.claude-<name>`.
3. Link the shared items. Do this while no session of the new profile runs.

   ```sh
   for item in agents file-history history.jsonl output-styles plugins projects sessions settings.json skills; do
     ln -s "$HOME/.claude/$item" "$HOME/.claude-<name>/$item"
   done
   ```

4. Add the launcher to `~/.zshrc`, and add its line to the list in the `claude` guard:

   ```zsh
   claude<letter>() {
     CLAUDE_PROFILE=<name> CLAUDE_CONFIG_DIR="$HOME/.claude-<name>" command claude "$@"
   }
   alias claude-<name>=claude<letter>
   ```

5. Add `<name>` to the `case` list in `~/.zshenv`.
6. Edit the other files in Places that list profiles.
7. Install the policy helper again if you changed `.agents/claude/device/policy-helper.sh`. See Limit a sign-in.
8. Start `claude<letter>` and run `/login`.
9. To link the profile to a running editor, copy `"autoConnectIde": true` from the state file of another profile into the new state file.

## Check the setup

| Check | Command | Expected result |
| --- | --- | --- |
| Links | `ls -l ~/.claude-<name>` | Nine links that point into `~/.claude`. |
| Sign-in | `jq -r '.oauthAccount.emailAddress // "NOT SIGNED IN"' ~/.claude-<name>/.claude.json` | The signed-in email, or `NOT SIGNED IN`. For the default profile, read `~/.claude.json`. |
| Keychain | The list command in Credentials | One plain entry for the default profile. Each suffixed entry matches the suffix of one folder path. |
| Guard | `claude` | The list of launchers, and exit code 1. |
| Profile inside a session | `echo "$CLAUDE_PROFILE $CLAUDE_CONFIG_DIR"` | The profile name. A named profile also shows its folder. The default profile shows no folder. |
| Policy | `"/Library/Application Support/ClaudeCode/policy-helper.sh" \| jq 'keys'` | `["appendSystemPrompt","managedSettings"]`. |

## Limits

- The installed status line, `~/.local/bin/claude-statusline.sh`, is a separate copy of `.agents/claude/statusline.sh`. The two files differ. The installed copy lists profile labels in a `case`. The repository copy reads the label from `CLAUDE_PROFILE`.
- A shared `settings.json` means that one bad hook breaks every profile.
- An account limit does not stop a person who can edit a state file.
