# Security

Portside can see and signal processes on your Mac, so security reports are taken seriously.

## Reporting a problem

Please **don't open a public issue** for a vulnerability. Report it privately through
[GitHub's security advisories](https://github.com/guneysol/portside/security/advisories/new)
instead. You'll get a reply within a few days, and a fix will be released as soon as possible.
You'll be credited unless you'd rather not be.

## What Portside does and doesn't do

- It runs as your user. It never asks for sudo, and it can only stop processes you own.
- It makes **no network connections**. Links in the `⋯` menu only open your browser. When Docker is
  running, it lists and stops containers through Docker's local socket on your Mac, never over the
  network.
- It asks for no accessibility, screen recording or disk access permissions.
- The installer builds a tagged release from source. It doesn't download a prebuilt binary.

Only the latest release is supported. To update, run the install command again.
