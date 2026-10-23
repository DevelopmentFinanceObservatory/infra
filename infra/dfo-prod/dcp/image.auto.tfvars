# Machine-owned: dfo-dcp's deploy workflow force-pushes this repo's
# deploy/dcp-prod branch and opens a PR that changes only the line below.
#
# null makes main.tf fall back to upstream's image for dcp_version, until the
# first pin PR merges. Do not add a second variable here: other committed,
# non-secret dcp config belongs in dfo.auto.tfvars.
datacommons_services_image = "europe-west1-docker.pkg.dev/prod-fin-observatory/datacommons/dfo-services-image@sha256:7feb5032d9a437a59aee5bdc0e5f0e807a383fae42c68d38477bd7be6a51eeb6"
