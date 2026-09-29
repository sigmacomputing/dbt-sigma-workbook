{# Negative tests: each macro below builds something invalid and is EXPECTED to raise a compiler error.
   scripts/run_integration_tests_duckdb.sh runs them via `dbt run-operation` and fails if any of them
   succeeds, since that means the corresponding validation regressed. #}

{% macro _src() %}
{% do return(sigma_workbook.from_ref('stg_orders')) %}
{% endmacro %}

{% macro _tiny_page(elements) %}
{% do return(sigma_workbook.page('P', elements)) %}
{% endmacro %}

{% macro assert_empty_workbook_rejected() %}
{% do sigma_workbook.workbook('W', []) %}
{% endmacro %}

{% macro assert_empty_page_rejected() %}
{% do sigma_workbook.page('P', []) %}
{% endmacro %}

{% macro assert_duplicate_page_name_rejected() %}
{% set el = sigma_workbook.text('hello', key='a') %}
{% do sigma_workbook.workbook('W', [sigma_workbook.page('P', [el]), sigma_workbook.page('P', [sigma_workbook.text('x', key='b')])]) %}
{% endmacro %}

{% macro assert_duplicate_element_id_rejected() %}
{# same kind + same name => same id; the message must tell the user to set key= #}
{% set a = sigma_workbook.bar_chart(sigma_workbook_integration_tests._src(), 'region', 'Count()', name='Same') %}
{% set b = sigma_workbook.bar_chart(sigma_workbook_integration_tests._src(), 'segment', 'Count()', name='Same') %}
{% do sigma_workbook.workbook('W', [sigma_workbook.page('P', [a, b])]) %}
{% endmacro %}

{% macro assert_unnamed_element_rejected() %}
{% do sigma_workbook.bar_chart(sigma_workbook_integration_tests._src(), 'region', 'Count()') %}
{% endmacro %}

{% macro assert_unknown_color_token_rejected() %}
{% do sigma_workbook.color('chartreuse') %}
{% endmacro %}

{% macro assert_unknown_color_ref_rejected() %}
{% do sigma_workbook.color_ref('chartreuse') %}
{% endmacro %}

{% macro assert_bad_sort_direction_rejected() %}
{% do sigma_workbook.bar_chart(sigma_workbook_integration_tests._src(), 'region', 'Count()', name='B', sort_direction='sideways') %}
{% endmacro %}

{% macro assert_table_without_columns_rejected() %}
{% do sigma_workbook.table(sigma_workbook_integration_tests._src(), [], name='T') %}
{% endmacro %}

{% macro assert_pivot_without_axes_rejected() %}
{% do sigma_workbook.pivot_table(sigma_workbook_integration_tests._src(), 'Count()', name='P') %}
{% endmacro %}

{% macro assert_empty_container_rejected() %}
{% do sigma_workbook.container([], key='c') %}
{% endmacro %}

{% macro assert_overwide_element_rejected() %}
{% do sigma_workbook.workbook('W', [sigma_workbook.page('P', [sigma_workbook.text('wide', key='w', w=30)])]) %}
{% endmacro %}

{% macro assert_bad_source_rejected() %}
{% do sigma_workbook.table('stg_orders', ['region'], name='T') %}
{% endmacro %}

{% macro assert_bad_warehouse_path_rejected() %}
{% do sigma_workbook.warehouse_table(['just_a_table']) %}
{% endmacro %}

{% macro assert_missing_connection_id_rejected() %}
{# run with --vars "{sigma_connection_id: ''}" #}
{% do sigma_workbook.warehouse_table(['db', 'schema', 'table']) %}
{% endmacro %}

{% macro assert_unsupported_format_kind_rejected() %}
{% do sigma_workbook.format('currency', {}) %}
{% endmacro %}

{% macro assert_unsupported_format_option_rejected() %}
{% do sigma_workbook.format('datetime', {'currencySymbol': '$'}) %}
{% endmacro %}

{% macro assert_control_without_targets_rejected() %}
{% do sigma_workbook.list_control('Region', targets=[]) %}
{% endmacro %}

{% macro assert_control_with_foreign_target_rejected() %}
{% do sigma_workbook.list_control('Region', targets=[({'id': 'x'}, 'region')]) %}
{% endmacro %}

{% macro assert_unknown_chart_type_rejected() %}
{% do sigma_workbook.simple_dashboard('D', sigma_workbook_integration_tests._src(), charts=[{'type': 'radar'}]) %}
{% endmacro %}

{% macro assert_unknown_filter_type_rejected() %}
{% do sigma_workbook.simple_dashboard('D', sigma_workbook_integration_tests._src(), kpis=[{'value': 'Count()'}], filters=[{'type': 'astrology', 'name': 'X', 'column': 'region'}]) %}
{% endmacro %}

{% macro assert_empty_simple_dashboard_rejected() %}
{% do sigma_workbook.simple_dashboard('D', sigma_workbook_integration_tests._src()) %}
{% endmacro %}

{% macro assert_control_id_column_collision_rejected() %}
{# a control called 'region' next to a column called Region is a circular dependency in Sigma #}
{% set t = sigma_workbook.table(sigma_workbook_integration_tests._src(), ['region'], name='T') %}
{% set c = sigma_workbook.list_control('Region', targets=[(t, 'region')], control_id='region') %}
{% do sigma_workbook.workbook('W', [sigma_workbook.page('P', [c, t])]) %}
{% endmacro %}

{% macro assert_extend_id_rejected() %}
{% do sigma_workbook.extend(sigma_workbook.text('x', key='k'), {'id': 'hijacked'}) %}
{% endmacro %}

{% macro assert_extend_foreign_element_rejected() %}
{% do sigma_workbook.extend({'kind': 'text'}, {'body': 'x'}) %}
{% endmacro %}

{% macro assert_raw_without_key_rejected() %}
{% do sigma_workbook.raw('button', none, {'text': 'x'}) %}
{% endmacro %}

{% macro assert_raw_private_key_rejected() %}
{% do sigma_workbook.raw('button', 'b', {'_w': 99}) %}
{% endmacro %}

{% macro assert_bad_output_format_rejected() %}
{% do sigma_workbook.workbook('W', [sigma_workbook.page('P', [sigma_workbook.text('hi', key='t')])], output='xml') %}
{% endmacro %}

{% macro assert_leaderboard_without_dimensions_rejected() %}
{% do sigma_workbook.simple_leaderboard('L', sigma_workbook_integration_tests._src(), dimensions=[], measure='Count()') %}
{% endmacro %}

{% macro assert_malformed_field_rejected() %}
{% do sigma_workbook.table(sigma_workbook_integration_tests._src(), [{'name': 'no formula'}], name='T') %}
{% endmacro %}
