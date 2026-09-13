import Testing
@testable import MacPilot

struct ScreenControlSafetyTests {
    // MARK: - Turn off screen

    /// The regression behind "black screen does nothing on the lock screen":
    /// MacPilot's black cover cannot draw above the login window, so a locked
    /// session must be darkened the way the system itself darkens it — a plain
    /// display sleep. That swap is safe exactly there, because a display sleep
    /// can only lock what is not already locked.
    @Test func aLockedScreenIsDarkenedBySleepingTheDisplayInsteadOfCoveringIt() {
        #expect(DisplayOffApproach.forScreen(locked: true) == .systemSleep)
        #expect(DisplayOffApproach.forScreen(locked: false) == .blankCover)
    }

    /// The unlocked desktop keeps the opposite rule: a real display sleep
    /// would trip "require password after the display turns off" and lock a
    /// session the user only asked to black out.
    @Test func anUnlockedDesktopIsBlackedWithoutSleepingAnything() {
        #expect(DisplayOffApproach.forScreen(locked: false) != .systemSleep)
    }

    // MARK: - Password typing gate

    /// The gate is the last line of defense between the stored login password
    /// and whatever text field the user left focused before locking. Only a
    /// locked session whose password field holds the keyboard may receive
    /// keystrokes; an unlocked session aborts no matter what claims focus.
    @Test func passwordKeystrokesAreOnlyPostedIntoAReadyLockScreen() {
        #expect(PasswordTypingGate.command(locked: true, secureFieldFocused: true) == .type)
        #expect(PasswordTypingGate.command(locked: true, secureFieldFocused: false) == .revealField)
        #expect(PasswordTypingGate.command(locked: false, secureFieldFocused: true) == .abort)
        #expect(PasswordTypingGate.command(locked: false, secureFieldFocused: false) == .abort)
    }

    /// Mid-typing, only "the session is no longer locked" may stop the
    /// keystrokes. The lock UI can drop and re-raise its secure field while
    /// wake services settle; a locked session routes everything to the login
    /// window regardless, and the next attempt pre-clears the field, so a
    /// transient secure-input blip must not strand a half-typed password.
    @Test func typingStopsOnlyWhenTheSessionIsNoLongerLocked() {
        #expect(PasswordTypingGate.command(locked: true, secureFieldFocused: false) != .abort)
        #expect(PasswordTypingGate.command(locked: false, secureFieldFocused: true) == .abort)
    }

    /// The fast-unlock race: a manual unlock (Touch ID, a watch, typing the
    /// password) hands the session back with the pre-lock input focus intact.
    /// The gate has to treat that state — unlocked, whatever else is true —
    /// as an immediate abort, because that focused field is exactly where a
    /// leaked password would land.
    @Test func anUnlockedSessionAbortsEvenIfASecureFieldIsFocused() {
        #expect(PasswordTypingGate.command(locked: false, secureFieldFocused: true) == .abort)
    }
}
