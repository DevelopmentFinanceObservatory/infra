# Machine-owned: dfo-dcp's deploy workflow force-pushes this repo's
# deploy/dcp-prod branch and opens a PR that changes only the line below.
#
# null makes main.tf fall back to upstream's image for dcp_version, until the
# first pin PR merges. Do not add a second variable here: other committed,
# non-secret dcp config belongs in dfo.auto.tfvars.
datacommons_services_image = "europe-west1-docker.pkg.dev/prod-fin-observatory/datacommons/dfo-services-image@sha256:c9f956d43bbc749f785126a9601a0aaa7117da21feac8683c65441bbe2ca5e73"
