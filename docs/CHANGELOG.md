# Changelog

Each release's notes are the section for its version below; `scripts/release.sh --publish` uses them as the GitHub release notes.

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
