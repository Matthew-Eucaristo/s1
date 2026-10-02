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

- **Untrusted input:** model outputs. A model can propose anything; the
  action gate decides what may execute. Deny-listed actions (credentials,
  OTP, card numbers, purchases) never reach the actuator, and
  irreversible actions require explicit human confirmation.
- **Trusted boundary:** the `Gate` in `Sources/S1Core/Safety/` — every
  action from every brain passes through it before the actuator runs.
- **Least surprise:** kill switch checked every step; stuck-loop guard;
  every step logged to `steps.jsonl` with the deciding brain and reason.
- **Permissions:** s1 needs Accessibility + Screen Recording + Mic +
  Input Monitoring — the same grants screen-sharing and dictation apps
  need. It never asks for more.
- **Secrets:** none belong in the repo or logs. Config files may name
  endpoints and keys (`~/.s1/config.json`); those stay on your machine.

## Hardening notes for contributors

- Never log secrets, screenshot contents, or accessibility values that
  look like credentials.
- New action types must declare their safety class (read-only /
  reversible / irreversible) — the gate defaults to conservative.
- Process spawning (`mdfind`, scripts) must never interpolate model
  output into shell strings — pass arguments as arrays only.
