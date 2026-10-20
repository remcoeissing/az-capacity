# Azure Capacity and Quota Scripts

This repository stores scripts for investigating **Azure capacity, quotas, and
service availability**. The scripts help assess subscription-specific limits,
regional and SKU availability, Availability Zone support, and zone-redundant
deployment options before planning Azure workloads.

**PostgreSQL Flexible Server is a key focus**, with a dedicated script for
checking size availability and zone-redundant high availability (HA) support
in a selected region.

> Quota, service capabilities, and physical capacity are different. Available
> quota or an advertised SKU does not guarantee that Azure can deploy that
> configuration at the time of your request.

## Featured: PostgreSQL zone availability

[postgres/postgres-zr.sh](./postgres/postgres-zr.sh) checks Azure Database for
PostgreSQL Flexible Server capabilities for your subscription in a specified
region. Optionally filter to a single size; otherwise, it reports all sizes
returned by the service.

For each size, the report shows:

- **Availability Zones** reported for that SKU.
- **SKU zone redundancy**: whether its reported HA modes include `ZoneRedundant`.
- **Regional zone-redundant HA**: whether the service enables that feature for
  the subscription and region.
- **Effective zone-redundant HA**: combines the SKU, regional, tier, availability,
  and reported zone checks.
- **Availability and restrictions**, including any service-reported reasons.

These checks are separate: a SKU can list multiple zones without regional
zone-redundant HA being enabled. Burstable does not support HA, even if the
capability response advertises a zone-redundant SKU mode. Missing or conflicting
evidence is reported as `Unknown`.

### Prerequisites

- Bash and `jq`.
- For live queries: Azure CLI, an existing `az login`, and permission to read the
  selected subscription's PostgreSQL capabilities.

### Usage

Run these commands from the repository root:

```bash
# Report all PostgreSQL sizes in a region.
bash postgres/postgres-zr.sh \
  --subscription '<subscription-id-or-name>' \
  --region swedencentral

# Filter to one size; the Standard_ prefix is optional.
bash postgres/postgres-zr.sh \
  --subscription '<subscription-id-or-name>' \
  --region westeurope \
  --size D2ds_v4

# Inspect a saved response without Azure CLI or an Azure login.
bash postgres/postgres-zr.sh \
  --region swedencentral \
  --file examples/swedencentral.json
```

Omit `--subscription` to use the active Azure CLI subscription. The script uses
read-only queries and does not change that subscription. Size matching is exact
and case-insensitive.

Use `bash postgres/postgres-zr.sh --help` for all options and exit codes.
