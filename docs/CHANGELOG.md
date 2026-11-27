# Changelog

Each release's notes are the section for its version below; `scripts/release.sh --publish` uses them as the GitHub release notes.

## 0.1.27 - 2026-11-27

- You can collapse the window's sections: click a heading to hide or show Orchestrator, On-demand runners, Up next, Throughput, and the runner cards, which now sit together under a Runners heading. A collapsed section is one line with a short summary. Problems stay in red on it: orchestrator problems, stuck jobs, failed runs and runners that need attention. A section does not open by itself. Everything starts open, and Hangar remembers what you collapsed.

## 0.1.26 - 2026-11-27

- Each on-demand runner row now shows the job's name after the workflow's. Without it, two jobs from one run, such as the parts of a split test suite, looked like the same row twice. In a long row the end of the branch name is what gets cut off.

## 0.1.25 - 2026-11-27

- A run that belongs to a pull request now shows the pull request's number, as in "PR 12", in place of the CI run's number. This applies to the on-demand runner rows, Up next, runner cards and notifications. Other runs, such as those started by a push to main, keep the run number, and so does a run for which GitHub lists no pull request.

## 0.1.24 - 2026-11-27

- A job can start while GitHub still calls its whole run "queued". Hangar kept using the job list it had read before the job started, so an on-demand runner showed only "Running a job", and the job could stay under Up next. When a busy runner has no job, Hangar now reads the queued runs again.

## 0.1.23 - 2026-11-26

- "Typical wait" no longer shows 0s when the orchestrator has recorded no wait times. The Throughput card shows a dash, and the Orchestrator card leaves the line out. The missing wait times themselves are not fixed by this release.

## 0.1.22 - 2026-11-26

- If you run the runner orchestrator, the window now has a card for it above the on-demand runners. It shows the open problems and how long each has lasted, the latest five events, each labelled with what happened, with the number in the last 24 hours, and the typical wait today against the previous 7 days. Recommendations will show there too; the orchestrator starts sending them with a later orchestrator update. The typical wait is an average of each runner set's median wait, weighted by its number of runs. Days are counted in UTC. Hangar reads the orchestrator's state file from this Mac or, over SSH, from the other Macs it already watches. The card says when the orchestrator has stopped reporting, and when Hangar needs updating to read its file. It does not appear if no orchestrator has been seen.
- A Throughput card, below Up next, covers the last 6 hours: jobs completed in the last hour, workflow runs failed, jobs running and waiting now, and today's typical wait. Four charts on one time axis show jobs completed, runs failed, jobs running and jobs waiting in five-minute steps; point at one to read a time and its value. Running and waiting are the most seen at once in each five minutes. A run with several failed jobs counts once as a failed run, while jobs completed counts every job, so one figure cannot be subtracted from the other. Recent failures shows the latest six runs that had a failed job in the last 6 hours, with the time, repository, job, any runner fault, and "+N more in this run", or says there were none in that time. The orchestrator keeps only its last 20 failed jobs, so the list can count fewer runs than the failed figure above it. A run that first failed earlier is listed here but not counted there. The failed step is named only when Hangar has read that job from GitHub for its other cards: it asks GitHub for nothing extra, so the step of a job that finished while Hangar was closed may not appear. The last hour and the 6 hours are measured back from the orchestrator's last report. The card is hidden while the orchestrator is not reporting, and when its file has no throughput numbers.
- You are notified of each new orchestrator problem and when the orchestrator stops reporting. Notices for jobs killed for memory arrive with a later orchestrator update, which starts reporting those kills. A memory kill is announced only if it happened after Hangar started, or in the five minutes before. "Not reporting" is announced once Hangar has watched the orchestrator stay silent for five minutes, not counting time the Mac was asleep or Hangar could not poll. Quiet hours hold these notices, and they share the limit that folds a burst into one summary.
- When Hangar cannot reach the orchestrator's Mac and there is nothing current from it, the card says "Cannot reach" and the Mac's name instead of "Orchestrator not reporting", because the orchestrator may be fine. If another Mac that Hangar watches over SSH does respond, you are notified in the same words, after the same five minutes. If no other Mac Hangar watches over SSH responds, as when you are away from them, it does not notify; this Mac does not count. So there is no notice if they are all down at once, or if the orchestrator's Mac is the only one Hangar watches over SSH. Time spent like that does not count towards either notice. The orchestrator's Mac counts as reached if its file was read, even when Hangar's checks of its runners fail; another Mac counts as responding only when those checks work. If what Hangar sees keeps switching between the two before either has lasted five minutes, you are notified once, after 15 minutes of either, in the words that fit at that moment.

## 0.1.21 - 2026-11-26

- The Capacity window now counts on-demand runners. It showed only runners installed on your Macs, so while on-demand runners worked through a long queue every bar read as idle. A new section shows, by Mac and job queue, a bar for the average number of jobs running in each hour, with the average and the most at once over the hours recorded. It starts from this version, and counts while Hangar is open.
- Failed jobs on on-demand runners now appear under Recent failures and send a notification, with the same rule that stops a job that keeps failing from alerting each time. Not every failure is seen. Hangar sees them only while it is open, and can miss a job that failed more than 10 minutes before a poll, one in a run that ended cancelled or successful before Hangar saw the failed job, one in a long run that has dropped out of the newest 20 and ended between two polls, and jobs past the first 100 of a run. Check GitHub for the full record. Stall alerts are still for runners with their own card.
- Each runner's busy percentage now says how many of the 24 hours it covers, and runners seen in the last 24 hours but not lately are listed apart as past runners. A percentage from a single hour read like a whole day's.
- The longest wait now says when it happened and which job it was. For hours recorded by an earlier version it names the hour.

## 0.1.20 - 2026-11-26

- On-demand runners are no longer listed twice. GitHub ignores capital letters in repository names, but Hangar did not: a repository saved under two spellings (for example `My-App` and `my-app`) was read twice, so each of its on-demand runners had two rows and was counted twice. Hangar now treats them as one repository.

## 0.1.19 - 2026-11-25

- On-demand runners on a Mac with a second Docker daemon now show the Mac's name. A Mac can run its orchestrator in more than one Colima virtual machine (`orchestrator`, `orchestrator2`), and Hangar read only the first, so a runner in the second showed no Mac name. Hangar now reads every running `orchestrator` virtual machine on each Mac.

## 0.1.18 - 2026-11-24

- On-demand runners now show which Mac they are on. The "On-demand runners" card listed each runner by its set name only, and GitHub does not say where a runner runs, so with jobs spread over two Macs there was no way to tell. Hangar now reads the runner containers in each Mac's orchestrator virtual machine and shows the Mac's name under the set name, for example "iMac" or "mac-mini". A Mac that cannot be read, or whose orchestrator virtual machine is stopped, simply shows no name.

## 0.1.17 - 2026-11-18

- New setting, Repositories to always watch (Settings, under Hosts): one owner/name per line. Hangar reads the queue, running jobs and on-demand runners of these repositories whether or not a runner of theirs is currently visible, so a repository whose runner VM has been stopped since Hangar was first installed no longer shows "Queue is empty" with work in progress. 0.1.16 only remembered repositories it had already seen.

## 0.1.16 - 2026-11-18

- A repository no longer disappears from Hangar when its runners are in a stopped virtual machine. Hangar finds the repositories to read from the runner folders on each Mac, and a runner VM that has nothing to do can now be stopped, so a repository whose runners were all in it dropped out: its waiting jobs, its on-demand runners and its running jobs were no longer read, and the window said "Queue is empty" with work in progress. Hangar now remembers the repositories it has seen, between polls and between launches, and keeps reading them.

## 0.1.15 - 2026-11-18

- A runner on a long job now shows which job it is on. In 0.1.14 an on-demand runner, or any runner, whose job belonged to a run that GitHub had pushed out of its newest twenty showed only "Running a job", with no job name, step progress or time. Runs that are in progress are now fetched on their own, as queued runs already were.
- The window no longer cuts off its bottom. With many runner cards it is taller than the screen and scrolls, but the scroll bar was hidden, so "On-demand runners", "Up next" and the footer were out of sight. The footer (update notice, Capacity, Settings) is now pinned below the scrolling area, the scroll bar shows, and "On-demand runners" and "Up next" come first, above the runner cards, so work in progress is the part that stays in view.

## 0.1.14 - 2026-11-18

- On-demand runners now show. Runners that an orchestrator starts for a single job never had a card, and the jobs waiting for them were left out of "Up next", so Hangar read "Queue is empty" while a repository had a dozen runs waiting. Those waiting jobs are now listed with an "On demand" label and the note "Waiting for an on-demand runner", and they are never counted as stuck, because their runner does not exist until a slot is free. A new "On-demand runners" card lists each live one with the job it is running, or "Waiting for a job" when it is online but has none.
- A failure streak now ends when GitHub's job list shows the newest run of that job succeeded. A job shorter than a poll was never seen running, so its success never reached the streak and "Failed 3 times in a row here" stayed up after the job was fixed.
- A card now says when the virtual machines on its Mac are allowed more memory than the Mac has, so an over-committed Mac is visible before it runs short.
- New script `scripts/colima-nightly-restart.sh` and its launch agent: restarts each running Colima profile once a night, waiting for any job, so a VM that has grown to its full size hands its memory back to macOS.

## 0.1.13 - 2026-10-28

- A repository the GitHub token cannot read no longer freezes the whole window. Before, one such repository (for example a new product's repository that the token had not been given access to) made every poll fail, so every card stopped updating and showed a red "Repo not found or token cannot see it". Now it is a warning naming that repository ("the token cannot read this repo, it needs Actions and Administration: read"), and every other card keeps updating. A bad token, a rate limit or a network failure still stops the poll, because those affect every repository.

## 0.1.12 - 2026-10-23

- "Mac memory pressure: high" now appears only once macOS has reported memory pressure for five minutes in a row. macOS flips between normal and warning often on a busy Mac, so the note used to flicker on and off. The notification and the optional "Protect running jobs" setting use the same rule. The swap-use note is unchanged.

## 0.1.11 - 2026-10-22

- Fewer notifications. Hangar now remembers what it has already told you, even after it is quit and reopened, so it no longer repeats every current problem each time it starts.
- Each kind of alert has a cooldown: a given job's failure or stall once per day, a runner going offline once per hour, and disk, memory, repeat-failure and long-run notices once per six hours. A notice is matched by what it is about, not by its wording, so a changing figure no longer makes it a new alert.
- No more than four alerts in ten minutes. Anything beyond that is folded into one "More Hangar alerts" notification. The cards and the Capacity window still show everything.

## 0.1.10 - 2026-10-22

- A job that keeps failing now sends one notification, not one for every failure. When the same job (same repository, workflow and job name) fails again within 3 hours of its last failure, on any runner, the card still shows the failure and it is still recorded in the Capacity window, but there is no new notification. After 3 hours without a failure, the next one notifies again.

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
