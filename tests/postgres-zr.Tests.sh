#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
script=$PWD/postgres-zr.sh
scratch=$(mktemp -d)
trap 'rm -f -- "$scratch/capabilities.json" "$scratch/az.log"; rmdir -- "$scratch"' EXIT

check() {
    local expected=$1
    shift
    if output=$("$@" 2>&1); then status=0; else status=$?; fi
    if [[ $status != "$expected" ]]; then
        printf 'FAIL: expected exit %s, got %s: %s\n%s\n' "$expected" "$status" "$*" "$output" >&2
        exit 1
    fi
}

contains() {
    if ! grep -Eq -- "$1" <<< "$output"; then
        printf 'FAIL: missing pattern %s\n%s\n' "$1" "$output" >&2
        exit 1
    fi
}

check 0 bash "$script" --help
contains 'Usage:'
check 1 bash "$script"
contains 'region is required'
check 1 bash "$script" --region
check 1 bash "$script" --region 'West Europe'
check 1 bash "$script" --region westeurope --size
check 1 bash "$script" --unknown
check 1 bash "$script" --region westeurope --file "$scratch/missing.json"

check 0 bash "$script" --region swedencentral --file examples/swedencentral.json
[[ $(grep -Ec '^(Burstable|GeneralPurpose|MemoryOptimized) ' <<< "$output") == 71 ]]
contains '^GeneralPurpose +Standard_D2ds_v4 +1,2,3 +Yes +Yes +Yes +Available'
contains '^Burstable +Standard_B1ms +1,2,3 +Yes +Yes +No +Available +Burstable does not support HA'

check 0 bash "$script" --region westeurope --file examples/westeurope.json
[[ $(grep -Ec '^(Burstable|GeneralPurpose|MemoryOptimized) ' <<< "$output") == 126 ]]
contains '^GeneralPurpose +Standard_D2ds_v4 +1,2,3 +No +No +No +Available'

check 0 bash "$script" --region swedencentral --file examples/swedencentral.json --size d2DS_v4
[[ $(grep -Ec '^GeneralPurpose ' <<< "$output") == 1 ]]
contains '^GeneralPurpose +Standard_D2ds_v4 '
check 0 bash "$script" --region swedencentral --file examples/swedencentral.json --size STANDARD_D2DS_V4
[[ $(grep -Ec '^GeneralPurpose ' <<< "$output") == 1 ]]
check 2 bash "$script" --region swedencentral --file examples/swedencentral.json --size D2
contains 'No PostgreSQL sizes found'

write_fixture() {
    jq "$1" examples/swedencentral.json > "$scratch/capabilities.json"
}

write_fixture '.[0].supportedFeatures |= map(select(.name != "ZoneRedundantHa"))'
check 0 bash "$script" --region test --file "$scratch/capabilities.json" --size D2ds_v4
contains '^GeneralPurpose +Standard_D2ds_v4 +1,2,3 +Yes +Yes +Yes +Available'

write_fixture 'del(.[0].zoneRedundantHaSupported) | .[0].supportedFeatures |= map(select(.name != "ZoneRedundantHa"))'
check 0 bash "$script" --region test --file "$scratch/capabilities.json" --size D2ds_v4
contains '^GeneralPurpose +Standard_D2ds_v4 +1,2,3 +Yes +Unknown +Unknown +Available'

write_fixture '.[0].supportedFeatures += [{"name":"ZoneRedundantHa","status":"Disabled"}]'
check 0 bash "$script" --region test --file "$scratch/capabilities.json" --size D2ds_v4
contains '^GeneralPurpose +Standard_D2ds_v4 +1,2,3 +Yes +Unknown +Unknown +Available'

write_fixture '(.[0].supportedServerEditions[].supportedServerSkus[] | select(.name == "Standard_D2ds_v4")) |= del(.supportedHaMode, .supportedZones)'
check 0 bash "$script" --region test --file "$scratch/capabilities.json" --size D2ds_v4
contains '^GeneralPurpose +Standard_D2ds_v4 +Unknown +Unknown +Yes +Unknown +Available'

write_fixture '(.[0].supportedServerEditions[].supportedServerSkus[] | select(.name == "Standard_D2ds_v4")).supportedZones = ["1"]'
check 0 bash "$script" --region test --file "$scratch/capabilities.json" --size D2ds_v4
contains '^GeneralPurpose +Standard_D2ds_v4 +1 +Yes +Yes +Unknown +Available'

write_fixture '.[0].restricted = "Enabled" | .[0].reason = "Subscription restriction"'
check 0 bash "$script" --region test --file "$scratch/capabilities.json" --size D2ds_v4
contains '^GeneralPurpose +Standard_D2ds_v4 +1,2,3 +Yes +Yes +No +NotAvailable'
contains 'Subscription restriction'

write_fixture '(.[0].supportedFeatures[] | select(.name == "OfferRestricted")).status = "Enabled"'
check 0 bash "$script" --region test --file "$scratch/capabilities.json" --size D2ds_v4
contains '^GeneralPurpose +Standard_D2ds_v4 +1,2,3 +Yes +Yes +No +NotAvailable +RegionRestricted'

check 0 bash "$script" --region test --file tests/fixtures/postgresql.json
contains '^GeneralPurpose +Standard_D4ds_v4 +1,2 +Yes +Yes +No +NotAvailable +Subscription SKU restriction'

write_fixture '.[0].supportedServerEditions[] |= (.status = "UnexpectedStatus")'
check 0 bash "$script" --region test --file "$scratch/capabilities.json" --size D2ds_v4
contains '^GeneralPurpose +Standard_D2ds_v4 +1,2,3 +Yes +Yes +Unknown +Unknown'

printf '{bad json' > "$scratch/capabilities.json"
check 1 bash "$script" --region test --file "$scratch/capabilities.json"
printf '{}' > "$scratch/capabilities.json"
check 1 bash "$script" --region test --file "$scratch/capabilities.json"
printf '[{}]' > "$scratch/capabilities.json"
check 1 bash "$script" --region test --file "$scratch/capabilities.json"
printf '[] []' > "$scratch/capabilities.json"
check 1 bash "$script" --region test --file "$scratch/capabilities.json"
printf '[]' > "$scratch/capabilities.json"
check 2 bash "$script" --region test --file "$scratch/capabilities.json"

export AZ_TEST_LOG=$scratch/az.log
export AZ_TEST_FAILURE=''
az() {
    printf '%s\n' "$*" >> "$AZ_TEST_LOG"
    case "$1 $2" in
        'account show')
            if [[ $AZ_TEST_FAILURE == account ]]; then
                printf 'Synthetic authentication failure\n' >&2
                return 1
            fi
            printf '11111111-2222-3333-4444-555555555555\r\n'
            ;;
        'postgres flexible-server')
            if [[ $AZ_TEST_FAILURE == capabilities ]]; then
                printf 'Synthetic capability request failure\n' >&2
                return 1
            fi
            cat examples/swedencentral.json
            ;;
        *) printf 'Unexpected Azure CLI call: %s\n' "$*" >&2; return 1 ;;
    esac
}
export -f az

check 0 bash "$script" --subscription 'Test Subscription' --region swedencentral --size D2ds_v4
contains 'Subscription: 11111111-2222-3333-4444-555555555555'
contains '^GeneralPurpose +Standard_D2ds_v4 +1,2,3 +Yes +Yes +Yes +Available'
grep -Fq -- 'account show --subscription Test Subscription --query id --output tsv --only-show-errors' "$AZ_TEST_LOG"
grep -Fq -- 'postgres flexible-server list-skus --subscription 11111111-2222-3333-4444-555555555555 --location swedencentral --output json --only-show-errors' "$AZ_TEST_LOG"

: > "$AZ_TEST_LOG"
check 0 bash "$script" --region swedencentral --size D2ds_v4
grep -Fq -- 'account show --query id --output tsv --only-show-errors' "$AZ_TEST_LOG"
AZ_TEST_FAILURE=account
check 1 bash "$script" --region swedencentral
contains 'Synthetic authentication failure'
AZ_TEST_FAILURE=capabilities
check 1 bash "$script" --region swedencentral
contains 'Synthetic capability request failure'

printf 'PASS: sample reports, filters, HA states, restrictions, errors and Azure CLI context.\n'
