# Coverage and known limits

An initial version aimed at dashboards.

- **Validated by Sigma and rendered by hand.** CI checks every workbook against the request schema in Sigma's public OpenAPI. Output was also checked with `POST /v2/workbooks` and `dryRun: true` against a real organization, and generated workbooks have been opened in Sigma. A dry run validates formulas, references, sources, connections and layout, but not how the result *looks* or whether an unqualified `[Column]` resolves. Workbooks as code is Beta and its API can change; run `--push --dry-run` against your own organization first. CI has no Sigma credentials, so rendering is not covered by automated tests.
- **Modeled elements**: table, KPI, bar / line / area / scatter / pie / donut charts, pivot table, text, divider, container, list / date-range / text / number-range controls. Not modeled (use [`raw`](README.md#escape-hatches)): maps, combo / waterfall / funnel / gauge / sankey / treemap / box charts, input tables, buttons and actions, forms, images, embeds, tabbed containers, modals and drawers, conditional formatting, reference marks, trellis.
- **Controls target any data element**, but Sigma's documented filter target is a table. Confirm chart/KPI targets with `--dry-run`.
- **Layout is flow-only**: no absolute x/y placement or spanning rows.
- **Source paths use `target.database` / `target.schema`** unless overridden.
- **Formulas are strings**; the package cannot check them against your data.
- **Workbook-level `theme=`** changes colors, palettes, fonts and page width; `cards` is project-level.
- One `sigma_workbook` per model; other `meta` keys are lost to `materialize()`.
- **Dashboard styles**: `simple_leaderboard` ranks its bar charts (largest first) but its breakdown pivot keeps Sigma's default order, and there is no top-N cut-off. Funnel, waterfall, gauge and cohort/heat-map styles need elements that aren't modeled (see above).
