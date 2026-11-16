# Desktop native initial validation — 2026-11-16

Follow-up: [native lifecycle validation and macOS fixes](2026-11-16-desktop-native-lifecycle.md).
The initial blocked results below are historical; the follow-up records candidate
macOS and Windows CLI success without claiming public entry activation.

Scope: user-authorized Mac and Windows testing, brief DDNSTO service interruptions
allowed. No reboot, logout, downgrade, or production deployment. Credentials and
binding token are deliberately omitted from this record.

## macOS — blocked before installation

- Target: 192.168.9.197, builder, macOS 26.6.2 / 25G83, arm64.
- User GUI domain 501 exists. No running DDNSTO or managed installation found in
  the checked standard paths.
- Executed the public `https://web.toany.net/i` command with the supplied token.
- Actual result: exit 12, temporary directory considered writable by others.
  Installation did not begin; no service was changed.
- `/private/tmp` is root-owned and `drwxrwxrwt`; `/` and `/private` are 0755.
- Actual native stat results for `/private/tmp`:
  - `%u %Lp %l`: `0 777 8`
  - `%u %Mp%Lp %l`: `0 1777 8`
- `ddnsto/portable-files.sh` uses `%Lp` on Darwin, losing special mode bits.
  Recommendation entry therefore cannot observe the sticky bit it requires.
- Root cause established by native metadata comparison. No permissions were
  relaxed, no check bypassed, and no installer fix or deployment performed.
- Fresh installation, upgrade, repeat execution, and lifecycle checks remain
  unverified until the entry compatibility issue is fixed and retested.

## Windows — package and desktop process only

- Target: 192.168.9.199, admin, Windows 10.0.26200.0, 64-bit, active desktop
  session 2. No running DDNSTO, matching service or scheduled task found initially.
- Official GUI 4.2.8 ZIP downloaded on the target over HTTPS (HTTP 200).
- ZIP SHA256: `5af347ac461e293106682b6c71492a50836b6df36a39434496e4d687f3214128`.
- Extracted executable SHA256 matches bundled `version.txt`:
  `b99aaca97d9c1f2e014ed8ae5185af7c2c3626da23e8829fb4bee38cdd8f7864`.
  This is archive consistency evidence, not an independent signature check.
- Files retained in
  `C:\Users\admin\AppData\Local\DDNSTO-Validation-20261116\client`.
- A temporary Interactive/Limited scheduled task launched the executable in the
  existing admin desktop. Observed PID 3252, SessionId 2, Responding True, empty
  MainWindowTitle. The temporary launch task was then unregistered.
- Process existence does not prove a visible usable window. No token was written
  through a config-file shortcut or backend call. User-visible entry, token
  saving, service setup and restart still require interactive desktop validation.
- GUI process and downloaded files retained for that validation. No existing
  user data removed or replaced.

Neither device had a running old version, so this round is not cross-version
upgrade acceptance. No cloud-online or remote-access claim is made.
