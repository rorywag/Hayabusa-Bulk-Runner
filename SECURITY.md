# Security

## Reporting a vulnerability

Please don't open a public issue for a security problem. Report it privately
through this repository's **Security** tab, using **Report a vulnerability**.
That opens a private advisory only the maintainer can see.

Include what you can of:

- what the problem is and where it is (file, function, or the input that triggers it)
- steps or a small synthetic input that reproduces it
- what an attacker could do with it
- the PowerShell version (5.1 or 7) and Windows version you saw it on

Please don't send real evidence, client data or anything identifying a real
host. A synthetic reproduction is always enough.

I'll acknowledge a report as soon as I can, usually within a week, and keep
you posted while it's looked at. This is a one-person project, so I can't
promise fix times, but security reports come first.

## Supported versions

Only the latest `main` is supported. Fixes aren't backported.

## Scope

In scope is this tool's own code, in particular how it handles hostile input:

- ZIP handling: path traversal, size and ratio limits, entries that lie about
  their size, unsupported or encrypted entries
- disk images: anything that could write to the evidence image, or leave an
  image attached after a run
- the dashboard: HTML or script injection from rule titles, host names or
  other values taken from the evidence
- the CSV outputs and manifest: formula injection
- the config file: anything that gets it to run code
- anything that writes outside OutputRoot or deletes outside its own
  working folders

Out of scope are bugs in Hayabusa itself, its rules, KAPE, or Windows. Please
report those to their own projects.
