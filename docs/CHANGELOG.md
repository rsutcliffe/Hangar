# Changelog

Each release's notes are the section for its version below; `scripts/release.sh --publish` uses them as the GitHub release notes.

## 0.1.4 - 2026-10-15

- The note on a runner that is behind now reads "Runner update available", and hovering it shows the installed and latest runner versions, so it is not mistaken for an update to Colima.
- A low-disk warning for a Colima runner now says "VM disk", because it measures the VM's own disk. Runners that share a VM disk show the warning once instead of on every card, and the notification is sent once.

## 0.1.3 - 2026-10-15

- When another Mac cannot be reached because macOS has not yet allowed Local Network access, Hangar now says so and offers a button that opens that setting, instead of showing a raw SSH error.
- On first launch a short note explains the Notifications and Local Network permission prompts, and Hangar asks for Local Network access straight away so the prompt does not appear to come from a failure.
- The window and Settings now tell you when a newer version of Hangar is available, with a link to download it. This can be turned off in Settings.

## 0.1.2 - 2026-10-15

- Failed jobs are now remembered: the Capacity window lists recent failures with the runner, the job and the step that failed, and each one opens the job on GitHub. The last 200 failures from the past 30 days are kept on your Mac, as names and times only.

## 0.1.1 - 2026-10-15

- Capacity and Settings links at the bottom of the window open the capacity history and Settings, so they no longer have to be found in the menus.
- Runner cards in the same row are now the same height, with their buttons level.

## 0.1.0 - 2026-10-15

First release.

- One window showing every self-hosted GitHub Actions runner on this Mac, other Macs over SSH, and inside Colima VMs: state, current job and step, CPU and memory, and the shared queue.
- Flags stalls (silent log and idle CPU), failures (with the failed step and a link to the job), jobs that no online runner can take, low disk space and runners behind the latest runner release.
- Notifications for stalls, failures and unexpected outages; a Dock badge counts runners that need attention.
- Restart and Drain/Resume per runner, with a check that a restarted runner comes back.
- A Capacity window with 24 hours of runner use and queue length.
- Test connection in Settings, optional launch at login and quiet hours for non-urgent alerts.
