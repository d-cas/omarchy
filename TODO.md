# dracut Migration - TODO List

**Target:** Pitch to DHH/Ryan before end of October 2025
**Status:** MVP Complete ✅ - Now polishing for pitch

---

## Before Next Session

- [ ] Push final commits: `git push origin feature/dracut-migration`
- [ ] Delete old remote branch: `git push origin --delete dracut-rebased`
- [ ] Delete backup directory: `rm -rf /mnt/truenas/dev-projects/omarchy_repos/omarchy.backup-20251019-170859`

---

## Week 1: Polish the Experience (Current Week)

### Plymouth Enhancement
- [ ] Review current `default/plymouth/omarchy.script`
- [ ] Add FIDO2-specific messaging/prompts
- [ ] Test with actual FIDO2 key
- [ ] Verify Tokyo Night colors (`#1a1b26`) are consistent

### Custom SDDM Theme
- [ ] Create `default/sddm/omarchy/` directory structure
- [ ] Design QML theme matching Plymouth
  - [ ] Create `Main.qml` (theme logic)
  - [ ] Create `theme.conf` (configuration)
  - [ ] Create `metadata.desktop` (metadata)
  - [ ] Copy Plymouth assets (logo.png, etc.)
- [ ] Update `install/login/sddm.sh` to use `Current=omarchy`
- [ ] Test theme looks good

### Multi-FIDO2 Testing
- [ ] Test with single FIDO2 key
- [ ] Test with 2 keys
- [ ] Test with 3+ keys
- [ ] Test with all 6 keys
- [ ] Document which combinations work
- [ ] Capture metrics (unlock time, detection speed)

---

## Week 2: Capture Problem & Solution

### Video 1: "The Problem" (2-3 min)
- [ ] Set up mkinitcpio test system
- [ ] Configure multiple FIDO2 keys
- [ ] Record boot with video capture dongle
- [ ] Show the hang/freeze with timer
- [ ] Demonstrate user frustration

### Video 2: "The Solution" (3-4 min)
- [ ] Record dracut boot with same hardware
- [ ] Show smooth Plymouth boot
- [ ] Show FIDO2 multi-key working
- [ ] Show seamless SDDM transition
- [ ] Show desktop ready
- [ ] Add metrics overlay

### Gather Benchmarks
- [ ] Package sizes: `pacman -Qi mkinitcpio dracut | grep "Installed Size"`
- [ ] Initramfs sizes: `ls -lh /boot/initramfs-*.img`
- [ ] Boot times: `systemd-analyze` (both versions)
- [ ] Detailed timing: `systemd-analyze blame`
- [ ] Document all metrics in comparison table

---

## Week 3: Polish & Testing

### Video Editing
- [ ] Edit problem video with professional intro/outro
- [ ] Edit solution video with metrics overlay
- [ ] Create side-by-side comparison (optional)
- [ ] Add captions/annotations
- [ ] Upload to YouTube/hosting

### Technical Documentation
- [ ] Create metrics comparison document
- [ ] Document code complexity reduction (lines removed)
- [ ] Research industry adoption statistics
- [ ] Write up "Why dracut" technical brief

### Real Hardware Testing
- [ ] Install on actual machine (not VM)
- [ ] Test boot flow
- [ ] Test FIDO2 with all keys
- [ ] Document any hardware-specific issues
- [ ] Get feedback from friend/colleague

---

## Week 4: Final Polish & Pitch

### Clean Up Repository
- [ ] Decide: keep or remove session docs (CONTEXT-QUICK-START, CRITICAL-FINDINGS, etc.)
- [ ] Option A: Remove from PR commits via cherry-pick to clean branch
- [ ] Option B: Keep on fork, don't include in PR
- [ ] Polish LUKS-DRACUT-IMPLEMENTATION.md (or remove if too verbose)
- [ ] Ensure code comments are professional

### Create Pitch Materials
- [ ] Write compelling PR description
  - [ ] Problem statement
  - [ ] Technical approach summary
  - [ ] Performance metrics
  - [ ] Video links
  - [ ] Call to action
- [ ] Optional: Create pitch deck/slides
- [ ] Prepare Q&A responses

### Submit Pitch
- [ ] Create PR or issue on basecamp/omarchy
- [ ] Tag DHH (@dhh) and Ryan Hughes
- [ ] Include video links prominently
- [ ] Monitor for questions
- [ ] Be ready to respond quickly

---

## Optional Enhancements (If Time Permits)

- [ ] Create migration script for existing mkinitcpio users
- [ ] Add archinstall configurator option (if making it optional)
- [ ] Write user documentation for FIDO2 setup
- [ ] Create troubleshooting guide
- [ ] Performance tuning documentation

---

## Questions to Answer Before Pitching

- [ ] What's the exact package size difference?
- [ ] What's the exact boot time difference?
- [ ] How many lines of code removed vs added?
- [ ] Which distributions use dracut?
- [ ] What's the maintenance status of mkinitcpio vs dracut?
- [ ] Are there any known dracut issues on Arch?

---

## Pitch Decision Points

Based on DHH/Ryan feedback, be ready to:

**If they want it as default:**
- Build migration script
- Document upgrade path
- Timeline for inclusion

**If they want it optional:**
- Modify archinstall configuration
- Add installer choice UI
- Keep mkinitcpio as default option

**If they need more convincing:**
- Gather more metrics
- Test on more hardware
- Get community feedback
- Demonstrate more FIDO2 scenarios

---

## Success Metrics

**Minimum:**
- [ ] Pitch submitted before end of October
- [ ] Videos demonstrate working FIDO2
- [ ] Metrics show comparable performance
- [ ] Code is clean and documented

**Target:**
- [ ] DHH/Ryan respond positively
- [ ] They agree to merge (as default or optional)
- [ ] Timeline established for inclusion

**Dream:**
- [ ] Merged as default for Omarchy 3.2.0
- [ ] Community celebrates
- [ ] FIDO2 just works for everyone

---

## Notes

- Keep BREADCRUMB logging - it's useful for debugging
- Test on VM first, then real hardware
- Video quality matters - make it professional
- DHH respects data - bring metrics, not just opinions
- Focus on pragmatism and "convention over configuration"

---

**Last Updated:** 2025-10-20
**See also:** PITCH-CONTEXT.md for complete context
