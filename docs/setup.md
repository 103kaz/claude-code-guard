# Setup

[日本語](setup.ja.md)

How to install code-guard, check that it works, change its settings, update it and remove it. Use the terminal if you are unsure: every step below works there.

## Requirements

- macOS or Linux (Windows is not supported)
- bash 3.2 or later, `jq` and `perl`
- Claude Code. See [Tested versions](../README.md#tested-versions)

Without `jq` or `perl` the guards block everything they cover and say how to install the tool.

## Install

The plugin is installed at user scope: it applies to every project on this machine. The terminal, the local sessions of the desktop app and the VS Code extension read the same settings files, so a plugin installed in one is available in the others. A cloud session does not load it.

### Terminal

In your shell:

```bash
claude plugin marketplace add 103kaz/claude-code-guard
claude plugin install code-guard@claude-code-guard
```

The second command prints `Successfully installed plugin: code-guard@claude-code-guard (scope: user)`. It also prints that some `userConfig` options are not set yet. Every option has a default, so you can ignore this; see [Settings](#settings).

Start a new session (`claude`) after installing. A session that was already open does not have the plugin; `/reload-plugins` loads it into that session.

You can also run the same steps inside a `claude` session: `/plugin marketplace add 103kaz/claude-code-guard`, then `/plugin install code-guard@claude-code-guard`. The install command opens the plugin's details; choose **Install for you (user scope)**.

### Desktop app

The marketplace has to be added first, and the desktop app's plugin browser lists only marketplaces that are already added. Add it once with the terminal command above (`claude plugin marketplace add 103kaz/claude-code-guard`).

Then, in a local or SSH session in the **Code** tab:

1. Click **+** next to the prompt box and select **Add plugins**. If the menu shows **Plugins** instead, select it, then **Browse plugins**.
2. Select **code-guard**.
3. Choose a scope. Your user account is the usual choice.

To enable, disable or uninstall the plugin later, use **Manage plugins** in the same menu. The plugin browser is not available in cloud sessions, and plugins are not available in WSL sessions.

## Check that it works

- In a new session, type `/`. `/code-guard:setup-verify` should be listed.
- In `/plugin`, open the **Installed** tab. `code-guard @ claude-code-guard` should show `Version: 0.2.1` (or later) and `Status: Enabled`.
- In your shell, `claude plugin list` prints the same information.

The plugin screens of the desktop app's settings can show a different list from the terminal. `claude plugin list` is the one to trust.

## Settings

Every option has a default, so nothing has to be set. To change one, open `/plugin` in a session, go to the **Installed** tab, select **code-guard** and choose **Configure options**. The options and their defaults are in the [README](../README.md#settings). They are read from the user's and managed settings only; a project cannot supply them.

## Update

Open the plugin on the **Installed** tab in `/plugin` and choose **Update now**, or run:

```bash
claude plugin update code-guard@claude-code-guard
```

The new version loads in the next session. Check `Version` as described above.

## Uninstall

```bash
claude plugin uninstall code-guard@claude-code-guard
```

Or choose **Uninstall** in the plugin's details in `/plugin`.

## When something does not work

| Symptom | Cause and fix |
|---|---|
| `claude plugin install` fails because the marketplace is unknown | Add it first: `claude plugin marketplace add 103kaz/claude-code-guard` |
| `/code-guard:...` is an unknown skill, or the guards do not stop anything | The session was opened before the install. Start a new session |
| Everything a guard covers is blocked and the message names `jq` or `perl` | Install the missing tool (`brew install jq` on macOS) |
| A project turned the plugin off | See [When a repository switches the plugin off](../README.md#when-a-repository-switches-the-plugin-off) |
| An error message from Claude Code | Open the **Errors** tab in `/plugin`, and see [Troubleshoot plugins](https://code.claude.com/docs/en/plugins/troubleshooting) |

## Next

- [What is guarded](../README.md#what-is-guarded)
- [Verify loop](../README.md#verify-loop): create `.claude/verify.sh` with `/code-guard:setup-verify`
