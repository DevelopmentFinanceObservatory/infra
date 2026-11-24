# pipelines — storage for the DFO data pipelines

The GCP footprint the `dfo-pipelines` repo reads and writes.

## Landing bucket

`<project>-pipelines-landing` is the pipelines' landing store: source files as downloaded, prefixed by source and dataset.

## Exports bucket

`<project>-pipelines-exports` is the pipelines' export store: Data Commons import bundles, prefixed by DCP import.

## BigQuery datasets

One dataset per upstream source in format `<source>_<dataset>` e.g. `oecd_dac_crs`. To add a source, append its dataset id to `local.bigquery_datasets` in `main.tf`.
