# scripts

## Getting the workbook into Sigma

`dbt parse` puts each request body at `manifest.json` -> `nodes.<model>.config.meta.sigma_workbook`. [`export_workbooks.py`](export_workbooks.py) is a dependency-free Python (3.9+) script that takes it from there. Run these from the root of your dbt project:

```bash
dbt parse
python scripts/export_workbooks.py --out sigma_workbooks/         # write one <model>.json per workbook
python scripts/export_workbooks.py --check                        # validate offline; non-zero on problems
python scripts/export_workbooks.py --select sigma_sales_dashboard --out sigma_workbooks/

export SIGMA_API_URL=https://api.sigmacomputing.com               # your region's API host
export SIGMA_CLIENT_ID=... SIGMA_CLIENT_SECRET=...
python scripts/export_workbooks.py --push --dry-run               # ask Sigma to validate, create nothing
python scripts/export_workbooks.py --push                         # create / update the workbooks
```

`--check` fails on an unresolved data model id, a missing `folderId`, duplicate element ids, or a warehouse source without a connection.

To **update** instead of creating another workbook, pass `sigma_workbook.workbook(..., workbook_id='<id>')`; the script sends `PUT /v2/workbooks/{id}/contents`. This creates a new version, and hand edits in Sigma to the same elements are replaced.

You can skip the script: the JSON is the exact body of [`POST /v2/workbooks`](https://help.sigmacomputing.com/reference/createworkbook).

### Output format

The default (`contents`) is Sigma's current API shape. `sigma_workbook_format: spec` (or `workbook(..., output='spec')`) emits the older nested shape used by the deprecated `/v2/workbooks/spec` endpoints:

| | `contents` (default) | `spec` |
| --- | --- | --- |
| Shape | `{name, folderId, description, contents: {schemaVersion, kind, pages, elements, settings, layout}}` | `{name, schemaVersion, folderId, pages: [{id, name, elements}], settings, layout}` |
| Endpoint | `POST /v2/workbooks`, `PUT /v2/workbooks/{id}/contents` | `POST /v2/workbooks/spec`, `PUT /v2/workbooks/{id}/spec` |
| Layout tags | `<Element>` / `<Container>` | `<LayoutElement>` / `<GridContainer>` |

The push script picks the endpoint from the shape, and the package emits the right layout tags for each (the current endpoint rejects the legacy ones).
