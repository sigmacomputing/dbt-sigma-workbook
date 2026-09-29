# scripts

## dbt 2 support

- `require-dbt-version: [">=1.6.0", "<3.0.0"]`, so dbt 2.x installs it.
- CI runs the entire integration suite on **both** dbt 1.12 and dbt 2.0 (the Rust engine published as `dbt-core` 2.x) on DuckDB.
- `macros/schema.yml` uses the argument types dbt 1.10+ / 2.x validate (`list[any]`, `dict[string,any]`, `bool`, `int`), and CI runs `dbt parse --warn-error` with `validate_macro_args: true`, so an argument documented under the wrong name fails the build.
- No `**kwargs`, no `adapter.dispatch`, no reliance on `execute`; every macro is pure Jinja that runs at parse time.
- Custom config lives under `meta`, the only place dbt 2 accepts non-standard keys on a model.
