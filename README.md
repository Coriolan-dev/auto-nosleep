# auto-nosleep

Use a MacBook with its lid closed, an external display, and battery power. auto-nosleep
automatically changes the macOS sleep setting when you connect or disconnect an external
display, so you do not have to run `pmset` yourself each time.

Normally, macOS requires external power for closed-lid use. Setting
`sudo pmset disablesleep 1` can keep it awake on battery, but also prevents normal sleep.
auto-nosleep applies that setting only while an external display is connected and restores
normal sleep when the last display disconnects.

| Situation | What happens |
| --- | --- |
| External display connected | Closed-lid use on battery is possible; system sleep is disabled |
| One of several external displays disconnected | Mac stays awake |
| Last external display disconnected | Normal sleep returns after a 15-second check |
| Idle with an external display connected | The app restores sleep and puts the Mac to sleep after the configured idle delay, checked every 10 minutes |

This is for a MacBook with an external display and a way to control it while the lid is
closed, such as an external keyboard and mouse or trackpad. It does not keep a Mac awake
with no external display. Keeping a Mac awake on battery uses more power; disconnect the
display or uninstall the app when you no longer need it.

## Install

Requirements: macOS 12 or newer, a MacBook, and Apple's Command Line Tools. The installer
opens the Command Line Tools installer if needed; after it finishes, run `./install.sh`
again.

1. Open Terminal and run:

   ```bash
   git clone https://github.com/Coriolan-dev/auto-nosleep.git
   cd auto-nosleep
   ./install.sh
   ```

2. Enter your Mac password when prompted. The installer compiles the Swift program,
   installs a per-user LaunchAgent, and adds a narrowly scoped sudo rule so the program
   can change the sleep setting. Read [Security](#security) for the exact commands.
3. If macOS reports **Background Items Added**, keep auto-nosleep enabled. It starts at
   login after a restart. If the installer says macOS blocked it, use the
   [troubleshooting steps](#troubleshooting).

To update, run `git pull` in the cloned folder and then `./install.sh` again.

## Check that it works

Connect an external display and run:

```bash
pmset -g | grep SleepDisabled
tail -f ~/Library/Logs/auto-nosleep.log
```

`SleepDisabled` should become `1` with an external display and return to `0` within
about 15 seconds after the last display disconnects. Press Ctrl-C to stop watching the
log. If the Mac is already idle when you connect a display, the app may immediately
restore sleep instead.

## Uninstall

From the cloned folder, run `./uninstall.sh` as your normal user. It stops the app,
restores normal sleep, and removes the installed program, LaunchAgent, log, and sudo rule.
It asks for your Mac password to remove the sudo rule.

If you need to restore normal sleep manually, run `sudo pmset disablesleep 0`.

## How it works

The program runs in your login session, watches display changes, and checks for any
external display. A 15-second delay confirms that the last display is gone before it
restores normal sleep. This avoids sleeping during brief display or dock changes.

Every 10 minutes it also checks idle time against the current `pmset` sleep and display
sleep settings. If the idle delay has passed and no app is preventing idle sleep, it
restores normal sleep and requests sleep. This means idle sleep can occur up to about
10 minutes after your configured delay. On wake, it checks the display again. On normal
logout or shutdown, it restores the sleep setting.

## Security

The program runs as your user. The installer adds `/etc/sudoers.d/auto-nosleep`, which
allows your user to run only these commands as root without entering a password each time:

```text
/usr/bin/pmset disablesleep 0
/usr/bin/pmset disablesleep 1
/usr/bin/pmset sleepnow
```

The sudo rule is validated before installation and removed by `./uninstall.sh`. The
installer asks for your password when it first adds the rule; the source code is built
locally on your Mac.

## Troubleshooting

- If macOS blocks startup, open **System Settings → General → Login Items & Extensions**,
  enable auto-nosleep under **Allow in the Background**, then run `./install.sh` again.
- If plugging in a display produces no log entry, check the agent with
  `launchctl print gui/$(id -u)/local.auto-nosleep | grep state`.
- If `SleepDisabled` stays at `1` after disconnecting the last display, run
  `sudo pmset disablesleep 0` and inspect the log for errors.

## License

MIT. See [LICENSE](LICENSE).
