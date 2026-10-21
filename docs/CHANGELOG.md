# Changelog

Each release's notes are the section for its version below; `scripts/release.sh --publish` uses them as the GitHub release notes.

## 0.1.9 - 2026-10-21

- New, off by default: "Protect running jobs when a Mac is low on memory" in Settings. While a Mac reports memory pressure, its idle runners are paused so the job already running has the best chance of finishing. A running job is never touched. The paused runners show "Held back: low memory" and resume once memory has been normal for 5 minutes, or when nothing on that Mac is running. If Hangar is quit while runners are held, it resumes them the next time it opens. It only works while Hangar is open.

## 0.1.8 - 2026-10-21

- A Mac that runs its runners only inside a virtual machine is now labelled with the Mac's own name on its cards, such as "iMac", instead of the name used inside the virtual machine ("colima").

## 0.1.7 - 2026-10-21

- A runner on a Mac that is short of memory now says so. When macOS reports memory pressure, or most of its swap is in use, one card on that Mac shows "Mac memory pressure: high" or "Mac swap 81% full", and a notification is sent once. Hover the line for the swap figures. A virtual machine on a Mac that is swapping slows down without any error inside it, which is hard to notice otherwise.
- "Failed N times in a row" now leaves the main window an hour after the last failure, so it only shows while it is current. The failures are still listed under Recent failures in the Capacity window.
- Notes that apply to a whole machine, such as low disk space or memory, now stay on the same card from one refresh to the next. They could previously move between cards.

## 0.1.6 - 2026-10-20

- Recent failures in the Capacity window now show the date and time each failure happened. The "minutes ago" they showed before were only worked out when the window was last drawn, so a window left open or minimised could show an old failure as just now. Hover a row to see how long ago it was.

## 0.1.5 - 2026-10-16

- A job that has just started is no longer wrongly shown as stalled. Hangar used to count the previous job's log as the new job's output, so a brief job could appear silent for an hour.
- A runner that is behind on its version now stays quiet for the first two weeks after a new release, because runners normally update themselves in that time. After that it shows "Runner update overdue" in red, since GitHub stops giving a runner jobs about a month after a release if it has not updated.

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
