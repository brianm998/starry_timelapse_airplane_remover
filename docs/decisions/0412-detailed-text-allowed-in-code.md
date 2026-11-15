# 0412 — The Detailed tab's English stays in code, allow-listed

Status: accepted (task #431, stage s419)

## Context

t249 split the Detailed text into sections whose headings are quoted literals. `NoHardCodedStringsTest` flags
those as hard-coded UI text and failed CI on develop.

## Decision

Allow-list the 13 literals in the test with a reason. The words are unchanged from before the split, pinned by
`InfoDialogTest`'s SHA-256, and the macOS gui holds them the same way. Moving them into the catalogue means 22
real translations of long prose in both clients, which is separate work.

## Consequences

The check still catches any new literal in `ui/`. Changing a Detailed literal needs the `ALLOWED` key changed too.
