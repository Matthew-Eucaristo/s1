# Security policy

s1 is a macOS automation agent — it can type, click, and read your screen.
That makes its safety posture part of the product, not an afterthought.

## Reporting a vulnerability

Please **do not** file a public issue for security problems. Instead:

- Open a [GitHub Security Advisory](https://github.com/Matthew-Eucaristo/s1/security/advisories/new) on this repo, or
- Contact the maintainer via the email on their GitHub profile.

Include: what happens, how to reproduce, which permission level is required
(Accessibility / Screen Recording / Input Monitoring), and the commit or
release you tested.

We aim to acknowledge reports within a few days.

## Threat model, briefly

- **Untrusted inputs:** model outputs AND screen content. A model can
  propose anything; the action gate decides what may execute. On-screen
  text (a hostile page, an email) goes to model prompts wrapped as
  untrusted data — only the user's goal is an instruction.
- **Deny-list covers:** credentials (any `*password*` form, PIN/OTP/CVV,
  keychain), purchases, destructive shell (`rm -rf`, `dd`→device,
  fork-bombs), process kills, power/session control, remote-script pipes,
  and executable URL schemes (`javascript:`, `data:text/html`) that
  paste-jack a browser.
- **Typed text is context-sensitive:** text headed for a focused
  AXSecureTextField (type or Cmd+V paste) or for a terminal app's
  command line gets escalated — in a terminal, even flag-less `rm`,
  `sudo`, `ssh`, force-push, and package removal route to a human.
- **Credential surfaces:** `openApp` names are deny-listed too — opening
  Passwords/1Password/Keychain Access needs a human. Secure-field
  AXValues are never read at all (not into the snapshot, the step log,
  or a model prompt).
- **Trusted boundary:** the `Gate` in `Sources/S1Core/Safety/` — every
  action from every brain passes through it before the actuator runs,
  and replay re-gates each recorded action against a live observation.
- **Least surprise:** kill switch checked every step (mid-wait too);
  stuck-loop guard; every step logged to `steps.jsonl` with the deciding
  brain and reason. `openApp` waits for the window server to make the
  app frontmost before returning, so the next observe — and the gate —
  sees the real keyboard owner.
- **Permissions:** s1 needs Accessibility + Screen Recording + Mic +
  Input Monitoring — the same grants screen-sharing and dictation apps
  need. It never asks for more.
- **Secrets:** none belong in the repo or logs. Config files may name
  endpoints and keys (`~/.s1/config.json`); those stay on your machine.

## Known limits (honest ones)

- The deny-list is regex matching on payloads — Unicode confusables,
  misspellings, and paraphrased danger can slip past it. It is a
  seatbelt, not a proof; assume motivated phrasing can evade it.
- Goal text and action payloads are logged verbatim to `steps.jsonl` —
  never put a real secret in a goal.
- Guards cover text *entry* into credential UI (type, paste, AX write).
  A click can't be scoped "not on the reveal-password eyeball" — keep
  secure surfaces out of agent goals entirely.
- Voice input trusts whoever is near the mic while the companion
  listens — the gate applies, but arm it where speech is yours.
- Screenshots capture whatever is on screen, including other apps'
  secrets — they go to run artifacts under `~/.s1` (owner-only) and,
  for VLM brains, to the configured endpoint.

## Hardening notes for contributors

- Never log secrets, screenshot contents, or accessibility values that
  look like credentials.
- New action types must declare their safety class (read-only /
  reversible / irreversible) — the gate defaults to conservative.
- Process spawning (`mdfind`, scripts) must never interpolate model
  output into shell strings — pass arguments as arrays only.
