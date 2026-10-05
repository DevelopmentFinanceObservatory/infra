# pipelines — storage for the DFO data pipelines

The GCP footprint the `dfo-pipelines` repo reads and writes.

## Raw data bucket

`<project>-pipelines-raw` holds source files as published, prefixed by source and dataset.

## Processed data bucket

`<project>-pipelines-processed` holds pipeline output, prefixed by DCP import.

## BigQuery datasets

One dataset per upstream source in format `<source>_<dataset>` e.g. `oecd_dac_crs`.
To add a source, append its dataset id to `local.bigquery_datasets` in `main.tf`.
