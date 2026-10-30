# gherkin/ui

The shared expectations for the macOS gui and the desktop client (see `plans/GUI_CLIENT_PARITY_PLAN.md`, §6).

* `commands.json` — the menu commands both clients offer, by the catalogue key of their label. Layer 0 of the plan: each client has a
  unit test (`CommandTableTests` in `gui/starTests`, `CommandTableTest` in `star-desktop/src/test`) that reads this file and checks its
  own menu code uses every key, so a command added to one client only is a failing test in the other. `knownGaps` lists, per client,
  what that client does not offer yet and why; an entry that is no longer true fails the test, so it has to be removed.

The identifier registry, the `@ui` features, the snapshots and the probes of §6.3 are not written yet.
