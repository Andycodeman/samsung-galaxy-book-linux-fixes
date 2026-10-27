# Issue #44 — reply (POSTED)

Thread state when drafted (2026-10-27): issue closed 2026-04-26 by @derwismtz.
@rocoboy reported left-channel crackle on 2026-08-29 (940XFG, board
`NP940XFG-KA1AR`, Fedora 44, kernel 7.1.10) and never got a reply. @maticomba
posted a Windows driver trace + replay fix on 2026-10-27 (same board as
rocoboy). No earlier ask in the thread asked rocoboy to test anything, so
this ask is new.

Posted 2026-10-27 after v0.3.97 shipped the `0x239e` removal, as
https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/issues/44#issuecomment-6453625880.
The posted text is the draft below with paragraphs unwrapped and a v0.3.97
link added after "`speaker-fix-940xfg`".

---

@maticomba thank you, this is excellent work. Running the real Windows
install under QEMU with the HDA controller passed through, then tracing every
CORB verb, is exactly the capture we wanted on this thread back in April and
couldn't get (rtport.sys was blocked). It also settles the `0x239e` question:
our script wrote `0x0004` there because the RtHDDump snapshots showed it, and
your trace shows Windows only ever reads it. I've removed that write from
`speaker-fix-940xfg` and corrected the docs, which now credit you and link
your repo for anyone who wants the full Windows tuning.

@rocoboy sorry your report sat for so long without a reply. Your board
(`NP940XFG-KA1AR`) is the same one @maticomba captured. His fix loads the
crossover/EQ filters and the speaker protection that Windows uses and our fix
doesn't, so it's the most likely answer to your left-channel distortion. When
you have time, could you try it and tell us whether the crackle is gone?

1. Uninstall our fix first (his installer checks for it). From the
   `speaker-fix-940xfg` folder you installed from:
   ```bash
   sudo ./uninstall.sh
   ```
2. Follow the steps in his README:
   https://github.com/maticomba/linux-galaxy-book3-pro-speakers#tldr--install.
   Start with the one-off test (step 1), **with the volume at 20–30%** as his
   README says, before installing anything.
3. Let us know:
   - whether the left side is clean now at low, medium and high volume
   - whether both sides still play (left and right, tweeters and woofers)
   - if you install it, whether sound survives a suspend/resume

If it fixes the crackle for you as well, that's a second confirmed machine.
It would also tell us whether it's worth adding the Windows tuning to our fix
as an option. If it doesn't help, please say so too; that's just as useful.
