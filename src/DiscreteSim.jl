"""
    DiscreteSim

Discrete-event simulation for Julia: a next-event calendar, coroutines for
processes, resources with queues, statistics that know what they measure,
experiments with confidence intervals, models calibrated from plant data, and a
printout that becomes a PDF.

The package is built around three ideas:

* **Everything categorical is a `Symbol`.** Entities, event kinds, resources,
  disciplines, distributions, metrics, data sources and verdicts are symbols, and
  the containers are symbol-keyed (`SymDict`) and ordered, so a model, a scenario,
  an experiment and a report all speak the same language.
* **A run is a pure function of its seed.** Streams are named, ties in the
  calendar are broken by insertion, and the whole study is reproduced from one
  number -- which is what makes a comparison of two designs meaningful.
* **Offline first.** Every artefact is generated locally; the periodic online
  feed is an addition that never breaks the pipeline, and the decision it
  justifies (recalibrate or keep) is written down.

The engine is organised as: `symbols`/`symdict` (the vocabulary and the
container), `calendar`/`types`/`clock`/`process` (the event loop and the
coroutines), `resources` (servers, containers, stores), `stats`/`trace`/`random`
(what is measured, recorded and drawn), `analytical` (the formulas a model has to
agree with), `experiments` (replications, warmup, comparisons), `models` (five
reference models), `data`/`online` (calibration and the periodic reevaluation),
`figures`/`printout`/`pdf` (the report), `notebooks` (validation and headless
runs) and `pipeline` (the one call that produces everything).
"""
module DiscreteSim

using Dates
using Printf
using Random
using Statistics
using Base64

using Distributions
import Distributions: cdf, pdf, logpdf, fit
import Statistics: mean, std, var, quantile, median, cor
import Base: minimum, maximum

import StableRNGs
import Tables
import JSON3
import HTTP
import Plots

## ---- vocabulary and containers -------------------------------------------------
include("symbols.jl")
include("symdict.jl")
include("errors.jl")

## ---- the engine -----------------------------------------------------------------
include("calendar.jl")
include("types.jl")
include("clock.jl")
include("stats.jl")
include("trace.jl")
include("process.jl")
include("resources.jl")
include("random.jl")

## ---- analysis --------------------------------------------------------------------
include("analytical.jl")
include("experiments.jl")
include("models.jl")

## ---- data, offline first ---------------------------------------------------------
include("data.jl")
include("online.jl")

## ---- reporting and the pipeline ---------------------------------------------------
include("figures.jl")
include("printout.jl")
include("pdf.jl")
include("notebooks.jl")
include("pipeline.jl")

## ---- exports ---------------------------------------------------------------------

# vocabulary and containers
export SymDict, Sym, code_string, title_string, symbol_equal, symbolize_keys,
    symbolize_deep, stringify_keys, to_named_tuple, to_dict, subset, deep_merge,
    numeric_keys, common_keys, ENTITIES, EVENT_KINDS, RESOURCE_KINDS, DISCIPLINES,
    PROCESS_STATES, RESOURCE_STATES, STATISTIC_KINDS, SYSTEM_METRICS, METRIC_KINDS,
    METRIC_LABELS, DISTRIBUTION_KINDS, DATA_SOURCES, FRESHNESS, REEVALUATION_VERDICTS,
    ONLINE_POLICIES, FETCH_STATUSES, EXPERIMENT_KINDS, COMPARISON_VERDICTS,
    VALIDATION_VERDICTS, THEORY_KINDS, RUN_VERDICTS, UNITS, vocabulary_of,
    vocabulary_kinds, validate_vocabulary, metric_kind, metric_unit, metric_label,
    optimisation_direction, is_lower_better, relative_change, relative_error,
    format_duration, is_metric, is_entity, is_event_kind, is_resource_kind,
    is_discipline, is_distribution_kind, is_data_source, is_unit_of, @syms

# exceptions
export SimInterrupt, SimulationError

# the clock
export Sim, SimConfig, Event, Calendar, clock_time, pending, events_processed, time_unit,
    seed_of, stop_reason, is_stopped, schedule!, schedule_at!, callback!, next_time,
    step!, run!, advance!, stop!, reset!, warmup!, measured_span, resource!,
    statistic!, register!, metric!, metric, on!, emit!, push_event!, pop_event!,
    peek_event, cancel_event!, calendar_snapshot

# processes
export Process, spawn!, @process, hold!, hold_until!, block!, passivate!, activate!,
    activate_all!, interrupt!, cancel!, current_process, inside_process, process_id,
    process_name, state_of, is_finished, is_alive, is_waiting, is_blocked, sojourn_of,
    attribute, set_attribute!, process_states, live_processes, blocked_processes,
    describe_process, check_interrupt!, release_blocker!

# resources
export Resource, Container, Store, request!, acquire!, release!, use!, with!,
    preempt!, breakdown!, maintenance!, repair!, availability, utilisation, mean_wait,
    mean_service, mean_sojourn, mean_queue_length, mean_in_use, mean_level, mean_count,
    queue_length, in_use, free_capacity, holds, fill!, drain!, level_of, fill_ratio,
    store_item!, retrieve!, count_of, is_available, next_waiter_index

# statistics
export Tally, TimeWeighted, Counter, Histogram, Recorder, tally!, observe!, count!,
    record!, tally_record!, hist_record!, recorder_record!, mean_ci, half_width,
    standard_error, summary_of, statistics_table, reset_statistics!, n_of, total_of,
    quantile, value_of, track_threshold!, fraction_above, time_above, peak, tail_mean,
    moving_average, bin_centres, histogram_density, cdf, std, var, required_replications,
    cumulative_mean, autocorrelation, extrema_of, outlier_fence, fractions, most_common,
    n_statistics

# trace
export Trace, trace!, trace_table, trace_rows, trace_summary, is_truncated, rows_of,
    rows_of_entity, occupation_segments, completions, values_of, reset_trace!, last_time,
    events_after, entity_of, TraceTable

# random streams and distributions
export Stream, stream!, stream_seed, rand_stream, rand_index, rand_bool, dist, dist_spec,
    sample_rv, sample_n, sample_fitted, rv, describe_dist, mean_of, sd_of, cv_of, exp_rv,
    det_rv, norm_rv, log_normal_rv, unif_rv, tri_rv, weibull_rv, gamma_rv, poisson_rv,
    empirical_rv, discrete_rv, mean_of_rate, antithetic!, streams_table, Deterministic

# analytical
export theory, erlang_b, erlang_c, ks_test, kolmogorov_q, two_sample_ks, best_fit,
    fit_distribution, validate_against_theory, little_law, observed_summary,
    theoretical_utilisation

# experiments
export ExperimentConfig, ExperimentResult, experiment, run_replication, run_options,
    seed_for, collect_metrics, summarize_records, metric_ci, metric_value, metric_series,
    metric_keys, metric_table, replications_table, describe_experiment, warmup_analysis,
    batch_means, interpolate_series, sweep, sweep_rows, sweep_matrix, compare_scenarios,
    paired_comparison, factorial_design, factorial_rows, effect_row,
    metric_of_statistic, STATISTIC_METRIC_MAP, observed_from_experiment

# models
export MODELS, MODEL_CATALOGUE, SCENARIOS, catalogue, default_params, model_params,
    scenario_params, scenario_overrides, apply_scenario, model_scenarios, model_sim,
    model_entity, model_resource, model_series, model_names, build_model, build_scenario,
    build_calibrated_scenario, model_theory, validate_model, build_mmc,
    build_transfer_line, build_machine_shop, build_inventory, build_call_center,
    inventory_validation, expected_demand_size, wip_of, process_time,
    standard_statistics!, wip_statistics!, record_wip!

# data and calibration
export PlantHistory, generate_history, history_series, history_keys, summarize_history,
    write_history_csv, calibrate, calibrate_observations, inferred_parameters,
    model_params_from_calibration, calibration_table, bootstrap_ci

# online and reevaluation
export OnlineConfig, ReevaluationPlan, DEFAULT_ONLINE_URL, fetch_online, read_cache,
    write_cache, cache_path, freshness_of, timestamp, read_json_file, write_json_file,
    online_feed, write_online_feed, describe_feed, parse_observations, reevaluate,
    append_reevaluation, reevaluation_log, last_reevaluation, feed_row, plan_days, due,
    describe_plan, jsonable, write_json_payload, seconds_between, is_local_source,
    source_path

# figures
export FIGURE_SIZE, FIGURE_COLOURS, figure_theme, png_base64, data_uri, figure_of,
    figure_set, figure_plots, fig_wip, fig_wait_hist, fig_utilisation, fig_throughput,
    fig_scenarios, fig_sweep, fig_warmup, fig_validation, fig_calibration, fig_factorial,
    fig_convergence, fig_gantt, figure_from_png, png_data_uri, get_rows

# printout
export PRINTOUT_CSS, html_escape, fmt_number, fmt_metric, fmt_value, fmt_interval, badge,
    verdict_class, paragraph_html, list_html, callout_html, cards_html, table_html,
    kv_html, figure_html, section_html, write_printout, ANALYSIS_KEYS, section_of,
    report_meta, document_html, report_html, preview_section, section_document,
    report_subtitle, generation_stamp, print_section_pdf, print_report_pdf, print_all_sections,
    headline_cards, metrics_table_html, resources_table_html, comparison_body,
    figures_of

# pdf
export find_chrome, pdf_available, html_to_pdf, print_html_to_pdf, pdf_capability,
    CHROME_CANDIDATES

# notebooks
export notebook_files, notebook_cells, is_markdown_cell, cell_order_section,
    literal_interpolations,
    known_notebook_names, validate_notebook, validate_notebooks,
    print_validation_report, run_notebook, run_notebooks, print_notebook_report,
    pluto_module, cell_bindings, cell_references, PLUTO_CELL_MARKER, PLUTO_ORDER_MARKER

# pipeline
export PipelineConfig, path_of, study_experiment, config_record, analysis_bundle,
    study_json, run_study, load_study, manifest_of, report_manifest, result_json,
    result_from_json, figure_set_from_dir

end # module