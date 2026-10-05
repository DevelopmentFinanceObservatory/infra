# consumer-psc-network

A consumer's private network path to the shared Cloud SQL instance (`dfo-dev/platform`). The instance binds to no VPC. It publishes a Private Service Connect service attachment instead, so reachability is each consumer's own resource, not the instance's. This module builds that path (a dedicated VPC, a regional subnet, a reserved internal address, a forwarding rule targeting the attachment, and a private DNS zone answering for the instance's PSC name) so every consumer builds the same shape.

## No Cloud NAT, no firewall rules

Nothing else runs in this VPC. The only egress it carries today is the consumer's Cloud Run service reaching the PSC endpoint, private-ranges traffic that never needs a NAT gateway. `private_ip_google_access` is set on the subnet too, but it doesn't do the same for Google API calls: under the `cloud-run-service` module's `PRIVATE_RANGES_ONLY` egress (see that module's README), only RFC 1918 destinations are routed onto this VPC, and Google's API ranges are public IPs, so those calls still take the service's normal public path. Adding a NAT gateway would still be a standing charge with nothing to route through it. Likewise there are no firewall rules. Nothing listens here, so the usual allow-internal set would be guarding traffic that never happens.

## Both ends have to agree

The forwarding rule alone grants nothing. The instance's `allowed_consumer_projects` has to name the consumer's project too, or the endpoint sits there with no path through. See the platform stack's README for that side.

## DNS

The Cloud SQL connectors resolve the instance's PSC DNS name (its `dns_name` attribute, e.g. `bbd723248b19.3niso0mm9bket.northamerica-northeast1.sql.goog`) rather than accepting an IP directly. The instance's name resolves inside a consumer's VPC only once something there publishes it. This module answers for it with a hand-built private zone, apex-only (zone origin equals the one A record it holds), pointing at the consumer's own PSC endpoint address.

Each consumer gets its own zone because a private zone answers identically on every network it's attached to. Since each consumer has its own endpoint address, one zone shared across every consumer's VPC could only publish a single answer for all of them.

Google is previewing its own automation for this (hashicorp/terraform-provider-google#27774), a zone Cloud SQL manages per-instance rather than one hand-built per consumer. It's Preview-only today and the Terraform provider doesn't support it. Once that lands, retiring this module's zone becomes mandatory. Cloud DNS resolves the longest matching suffix, and this module's zone, naming the instance's exact PSC name, is more specific than a suffix-level zone Google would attach, so it would keep winning and shadow the automation's answer.

## Subnet ranges

Each consumer, in each environment, gets its own `/24` out of one `/16` per environment, so two ranges can never collide even if these VPCs are peered later:

| Environment | Block           | Consumer                                 | Subnet          |
| ----------- | --------------- | ---------------------------------------- | --------------- |
| `dfo-dev`   | `10.100.0.0/16` | `website`                                | `10.100.1.0/24` |
| `dfo-dev`   | `10.100.0.0/16` | `dcp` (reserved, no longer instantiated) | `10.100.2.0/24` |
| `dfo-dev`   | `10.100.0.0/16` | `apis`                                   | `10.100.3.0/24` |
| `dfo-dev`   | `10.100.0.0/16` | `ai`                                     | `10.100.4.0/24` |

A future environment takes the next `/16` (`10.101.0.0/16`, and so on), so no environment's ranges collide with another's either. Add a row here whenever a new consumer or environment is wired up. `10.100.2.0/24` stays reserved for `dcp` even though nothing instantiates it there anymore, so the range is never reissued to a different consumer.

## No `prevent_destroy`

Pre-release, none of this module's resources carry `prevent_destroy`: recreating a VPC, subnet, reserved address, or DNS zone costs nothing, and the block would obstruct the iteration this stage is for. `scripts/check-destroys.sh` covers the network, subnetwork, address, DNS zone, and DNS record set types instead, so an unintended teardown still fails CI unless the PR carries the `allow-destroy` label. A DNS zone's `name` and `dns_name` are both ForceNew, so renaming either one replaces the zone and, with it, the record set. The replacement shows up as a delete in plan output and needs the same label. Restore `prevent_destroy` at launch.

## Why a module

Every consumer needs the same five resources, varying only names, the subnet range, and the target project. Written as a module so `apis`, `website`, and `ai` stay identical in shape, and so a future consumer is one more instantiation, not a second copy of this file.
