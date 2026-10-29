#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Check Azure Database for PostgreSQL Flexible Server zone capabilities.

Usage:
  bash postgres-zr.sh --region REGION [--subscription ID_OR_NAME] [--size SKU]
  bash postgres-zr.sh --region REGION --file CAPABILITIES.json [--size SKU]

Options:
  -r, --region REGION          Azure region name, e.g. swedencentral (required).
  -s, --subscription VALUE     Subscription ID or name; defaults to the active one.
      --size SKU              Exact size, with or without Standard_ (case-insensitive).
      --file PATH             Read saved list-skus JSON instead of contacting Azure.
  -h, --help                  Show this help.

Requires Bash and jq; live queries also require Azure CLI and an existing az login.
Uses read-only commands and does not change the active subscription.

SKU-ZR:          SKU supportedHaMode contains ZoneRedundant.
REGION-ZR-HA:    Service-level ZoneRedundantHa feature for this subscription/region.
EFFECTIVE-ZR-HA: Combines SKU, region, tier and availability checks.
AZS:            Service-reported SKU zones, not a capacity guarantee.
Unknown:        Required capability data was absent, conflicting or unrecognized.

Exit codes: 0 = report produced; 1 = input/query/JSON error; 2 = no matching sizes.
EOF
}

fail() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

region=''
subscription=''
size=''
input_file=''
while (($#)); do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        -r|--region|-s|--subscription|--size|--file)
            option=$1
            (($# >= 2)) || fail "$option requires a value."
            [[ -n $2 && $2 != -* ]] || fail "$option requires a value."
            case "$option" in
                -r|--region) region=$2 ;;
                -s|--subscription) subscription=$2 ;;
                --size) size=$2 ;;
                --file) input_file=$2 ;;
            esac
            shift 2
            ;;
        *) fail "Unknown argument: $1. Use --help for usage." ;;
    esac
done

[[ -n $region ]] || fail '--region is required.'
[[ $region =~ ^[a-zA-Z0-9]+$ ]] || fail 'Use an Azure region name such as westeurope, not its display name.'
command -v jq >/dev/null 2>&1 || fail 'jq is required but was not found in PATH.'

if [[ -n $input_file ]]; then
    [[ -r $input_file ]] || fail "Cannot read capability file: $input_file"
    capabilities=$(cat -- "$input_file") || fail "Failed to read: $input_file"
    subscription_label='Offline (subscription and region of the file are not verified)'
else
    command -v az >/dev/null 2>&1 || fail 'Azure CLI (az) is required but was not found in PATH.'
    subscription_args=()
    if [[ -n $subscription ]]; then
        subscription_args=(--subscription "$subscription")
    fi
    subscription_id=$(az account show "${subscription_args[@]}" --query id --output tsv --only-show-errors) \
        || fail 'Could not resolve the subscription. Check az login and subscription access.'
    subscription_id=${subscription_id//$'\r'/}
    [[ $subscription_id =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]] \
        || fail 'Azure CLI did not return a valid subscription ID.'
    capabilities=$(AZURE_EXTENSION_USE_DYNAMIC_INSTALL=no az postgres flexible-server list-skus \
        --subscription "$subscription_id" --location "$region" --output json --only-show-errors) \
        || fail "Could not retrieve PostgreSQL capabilities for $region in $subscription_id."
    subscription_label=$subscription_id
fi

rows=$(jq -r -s --arg size "$size" '
    def state:
        if . == "Enabled" then "Yes"
        elif . == "Disabled" then "No"
        else "Unknown" end;
    def feature($name; $legacy):
        [.supportedFeatures[]? | select(.name == $name) | .status] | unique
        | if length == 0 then $legacy
          elif length == 1 then .[0]
          else "Unknown" end;
    def availability($nodes; $restriction):
        [$nodes[] | .status | select(. != null and . != "")] as $states
        | if $restriction == "Enabled"
             or any($states[]; . == "Disabled" or . == "Unavailable" or . == "NotAvailable")
          then "NotAvailable"
          elif ($restriction != null and $restriction != "Disabled")
             or any($states[]; . != "Available" and . != "Default")
          then "Unknown"
          else "Available" end;
    def normalized_size: ascii_downcase | sub("^standard_"; "");

    if length != 1 then error("Expected one JSON document") else .[0] end
    | if type == "array" then .
      elif type == "object" and (.value | type) == "array" then .value
      else error("Expected a list-skus array or an ARM object with a value array") end
    | if all(.[];
          type == "object" and (.supportedServerEditions | type) == "array"
          and all(.supportedServerEditions[];
              type == "object" and (.name | type) == "string"
              and (.supportedServerSkus | type) == "array"
              and all(.supportedServerSkus[];
                  type == "object" and (.name | type) == "string")))
      then . else error("Unrecognized PostgreSQL capability schema") end
    | [
        .[] as $root
        | ($root | feature("ZoneRedundantHa"; .zoneRedundantHaSupported) | state) as $region_ha
        | ($root
           | [.restricted, (.supportedFeatures[]?
               | select(.name == "Restricted" or .name == "OfferRestricted") | .status)]
           | map(select(. != null))
           | if index("Enabled") != null then "Enabled"
             elif any(.[]; . != "Disabled") then "Unknown"
             elif length > 0 then "Disabled"
             else null end) as $restriction
        | $root.supportedServerEditions[] as $tier
        | $tier.supportedServerSkus[]
        | select($size == "" or ((.name | normalized_size) == ($size | normalized_size)))
        | . as $sku
        | (if (.supportedHaMode | type) != "array" then "Unknown"
           elif (.supportedHaMode | index("ZoneRedundant")) != null then "Yes"
           else "No" end) as $sku_ha
        | (if (.supportedZones | type) == "array"
           then [.supportedZones[] | tostring | select(. != "" and . != "0" and . != "null")] | unique
           else [] end) as $zones
        | availability([$root, $tier, $sku]; $restriction) as $available
        | (if ($tier.name | ascii_downcase) == "burstable" or $sku_ha == "No"
                or $region_ha == "No" or $available == "NotAvailable" then "No"
           elif $sku_ha == "Yes" and $region_ha == "Yes"
                and $available == "Available" and ($zones | length) >= 2 then "Yes"
           else "Unknown" end) as $effective
        | ([$root.reason, $tier.reason, $sku.reason | select(. != null and . != "")]
           + (if $restriction == "Enabled" then ["RegionRestricted"]
              elif $restriction != null and $restriction != "Disabled" then ["RegionRestrictionUnknown"]
              else [] end)
           + (if ($tier.name | ascii_downcase) == "burstable" then ["Burstable does not support HA"] else [] end)
           | unique | if length == 0 then "-" else join("; ") end) as $reason
        | {tier: $tier.name, size: $sku.name,
           zones: (if ($zones | length) > 0 then ($zones | join(",")) else "Unknown" end),
           sku_ha: $sku_ha, region_ha: $region_ha, effective: $effective,
           available: $available, reason: $reason}
      ]
    | unique_by([.tier, .size, .zones, .sku_ha, .region_ha, .effective, .available, .reason])
    | sort_by(.tier, .size)
    | .[] | [.tier, .size, .zones, .sku_ha, .region_ha, .effective, .available, .reason] | @tsv
' <<< "$capabilities") || fail 'Could not parse PostgreSQL capability data (jq details above).'

if [[ -z $rows ]]; then
    printf 'No PostgreSQL sizes found for region %s%s.\n' "$region" "${size:+ matching $size}" >&2
    exit 2
fi

printf 'Subscription: %s\nRegion: %s\n\n' "$subscription_label" "$region"
format='%-18s %-28s %-9s %-8s %-12s %-16s %-14s %s\n'
printf "$format" 'TIER' 'SIZE' 'AZS' 'SKU-ZR' 'REGION-ZR-HA' 'EFFECTIVE-ZR-HA' 'AVAILABILITY' 'REASON'
while IFS=$'\t' read -r tier sku zones sku_ha region_ha effective available reason; do
    printf "$format" "$tier" "$sku" "$zones" "$sku_ha" "$region_ha" "$effective" "$available" "$reason"
done <<< "$rows"
printf '\nSKU-ZR is the reported SKU mode; EFFECTIVE-ZR-HA also checks region, tier and availability.\n'
printf 'Capabilities are not a quota check or a guarantee of current deployable capacity.\n'
