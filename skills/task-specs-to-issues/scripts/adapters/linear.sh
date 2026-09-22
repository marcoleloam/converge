#!/usr/bin/env bash
# adapters/linear.sh — Linear backend for task-specs-to-issues (DEFAULT tracker).
#
# Same five-verb contract as adapters/github.sh (see references/adapter-contract.md):
#   preflight | upsert | link | list-ready | write-result
#
# Talks to the Linear GraphQL API at https://api.linear.app/graphql with two env
# vars:
#   LINEAR_API_KEY   — a personal API key (lin_api_...). Sent as the raw
#                      Authorization header value (Linear's scheme, NOT Bearer).
#   LINEAR_TEAM_ID   — the team the issues live under: a team KEY (e.g. CVG,
#                      straight from the Linear URL .../team/CVG/...) OR the UUID.
#                      A key is resolved to its UUID automatically.
#
# Idempotency key: an ATTACHMENT carrying a unique, deterministic URL derived from
# the spec id (default https://cvg.local/task-spec/<id>, override with
# TSI_LINEAR_MARKER_BASE). This is Linear's own documented mechanism for stateless
# external integrations: "Attachment URL is used as an idempotent value ... you can
# query an attachment, and the associated issue, by its URL"
# (linear.app/developers/attachments). Upsert resolves the issue via
# attachmentsForURL first, so a re-run updates instead of duplicating.
# NOTE: Linear has NO `externalId` field on Issue/IssueCreateInput/IssueFilter —
# an earlier version of this adapter assumed one and every call failed.
#
# Dependency edges use Linear's native `issueRelation` of type `blocks`: the
# dependency issue `blocks` the dependent issue, which Linear surfaces as
# "blocked by" on the dependent side — a faithful mirror of `depends_on`.
#
# Every GraphQL call is isolated in a clearly-marked `_linear_gql*` function so
# the network surface is auditable in one place. This adapter TALKS TO THE
# NETWORK; register.sh --dry-run never invokes it.

set -euo pipefail

LINEAR_API_URL="${LINEAR_API_URL:-https://api.linear.app/graphql}"

# Directory of this adapter, for sourcing its function-only tier companions (below,
# just before dispatch — after the core helpers they lean on are defined).
_LN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

tsi_ln_die() { echo "ERROR (linear adapter): $*" >&2; exit 1; }

_ln_require_tools() {
  command -v curl >/dev/null 2>&1 || tsi_ln_die "curl not found on PATH"
  command -v jq >/dev/null 2>&1 || tsi_ln_die "jq not found on PATH"
}

# ===========================================================================
# GraphQL transport — the ONLY functions that touch the network.
# ===========================================================================
# _linear_gql QUERY VARIABLES_JSON
#   POSTs a GraphQL request. QUERY is the query/mutation string; VARIABLES_JSON
#   is a JSON object (default {}). Echoes the raw response JSON. Fails hard on a
#   transport error or a GraphQL `errors` array.
# Resolve the key from the OS secret store when it is not already in the
# environment.
#
# `cvg setup key linear` exists so you set the key ONCE instead of every session,
# and it stores into the macOS Keychain (or secret-tool, or a 0600 file). But this
# adapter only ever read $LINEAR_API_KEY, so a stored key was invisible to it:
# `tracker-key.sh status linear` reported TRACKER_KEY=OK from the Keychain while
# every board call died with "LINEAR_API_KEY unset". The resolver was written, and
# its only real consumer was never wired to it — so `cvg register` and its live
# parity gate could not run without a manual export, which is exactly the friction
# the key store was built to remove.
#
# Environment still WINS (CI, and anyone who prefers explicit); this is a fallback.
_linear_resolve_key() {
  [[ -n "${LINEAR_API_KEY:-}" ]] && return 0
  local resolver="${TSI_SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/tracker-key.sh"
  [[ -f "$resolver" ]] || return 0
  local v
  v="$(bash "$resolver" get linear 2>/dev/null || true)"
  [[ -n "$v" ]] && export LINEAR_API_KEY="$v"
  return 0
}

_linear_gql() {
  local query="$1"
  _linear_resolve_key
  # NB: do NOT write `${2:-{}}` — bash closes the expansion at the FIRST `}`, so an
  # explicit `{}` comes back as `{}}` (invalid JSON -> jq fails -> empty POST body).
  # That trap silently broke every Linear call until it was caught against the live API.
  local variables="${2:-}"
  [ -n "$variables" ] || variables='{}'
  [[ -n "${LINEAR_API_KEY:-}" ]] || tsi_ln_die "LINEAR_API_KEY unset"
  local payload resp
  payload="$(jq -n --arg q "$query" --argjson v "$variables" '{query:$q, variables:$v}')"
  resp="$(curl -sS -X POST "$LINEAR_API_URL" \
    -H "Content-Type: application/json" \
    -H "Authorization: ${LINEAR_API_KEY}" \
    --data "$payload")" || tsi_ln_die "GraphQL transport error"
  if printf '%s' "$resp" | jq -e '.errors' >/dev/null 2>&1; then
    echo "$resp" | jq -r '.errors[]?.message' >&2
    tsi_ln_die "GraphQL returned errors"
  fi
  printf '%s' "$resp"
}

# ---------------------------------------------------------------------------
# _ln_gql_soft QUERY [VARS] — fire-and-forget GraphQL for COSMETIC/optional writes.
# ---------------------------------------------------------------------------
# THE SUBSHELL IS LOAD-BEARING. _linear_gql hard-exits (tsi_ln_die) on a transport
# or GraphQL error, and a bare `|| true` CANNOT contain an `exit` — it only catches
# a non-zero RETURN. Without the subshell, one rejected optional field kills the
# whole adapter process mid-verb. That is exactly how a re-run's already-linked
# initiative truncated initiative-ensure's output and reported "(skipped)".
# Every fail-soft caller must go through this wrapper. Callers that need the
# RESPONSE are already safe, because `$( )` is itself a subshell.
_ln_gql_soft() {
  ( _linear_gql "$@" ) >/dev/null 2>&1 || true
  return 0
}

# ---------------------------------------------------------------------------
# Team resolution — accept a team KEY (e.g. CVG, straight from the Linear URL)
# OR a UUID. Issue mutations need the team's UUID, but humans have the key, so we
# resolve key -> UUID transparently. cvg exports an already-resolved UUID (looked
# up once during setup), so this only hits the network on the standalone path.
# ---------------------------------------------------------------------------
_ln_is_uuid() {
  printf '%s' "$1" | grep -qiE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
}

# Echo the team UUID for $LINEAR_TEAM_ID (a UUID passes through; a key is looked
# up via teams(filter:{key:{eq}})). Empty if unset or unresolvable.
_ln_resolve_team_id() {
  local tid="${LINEAR_TEAM_ID:-}"
  [[ -n "$tid" ]] || { printf ''; return 0; }
  if _ln_is_uuid "$tid"; then printf '%s' "$tid"; return 0; fi
  local resp
  resp="$(_linear_gql 'query($k:String!){ teams(filter:{ key:{ eq:$k } }){ nodes{ id key name } } }' \
    "$(jq -n --arg k "$tid" '{k:$k}')")" || { printf ''; return 1; }
  printf '%s' "$resp" | jq -r '.data.teams.nodes[0].id // empty'
}

# ---------------------------------------------------------------------------
# Triage metadata. The split is by OWNERSHIP, not by create-vs-update:
#
#   * DERIVED labels — `cvg`, `effort:*`, `backend:*`, `agent:*`, `severity:*` — are facts
#     read off the spec, so they are part of the PROJECTION and are kept in sync
#     on every register, exactly like the title and body. cvg owns that namespace
#     and nothing outside it.
#   * ANY OTHER label is the human's triage and is never added or removed.
#   * `priority` is human triage: seeded once at create, never touched again.
#
# (An earlier version seeded labels at create ONLY, which meant an issue created
# before labels existed could never acquire them — CVG-1 hit exactly that.)
# All of it is FAIL-SOFT: a cosmetic problem must never break a registration.
# ---------------------------------------------------------------------------
# Six-tier effort -> Linear's NATIVE estimate points. Linear's own T-shirt scale
# is XS=1 S=2 M=3 L=5 XL=8 XXL=13, which maps 1:1 onto the cvg sizing engine.
# Setting the native field (not just a label) is what makes Linear's velocity,
# burn-up and cycle-capacity views actually understand the work.
# Echoes empty for an unknown tier, so the field is simply omitted.
_ln_estimate_points() {
  case "$1" in
    XS|xs)   printf '1' ;;
    S|s)     printf '2' ;;
    M|m)     printf '3' ;;
    L|l)     printf '5' ;;
    XL|xl)   printf '8' ;;
    XXL|xxl) printf '13' ;;
    *)       printf '' ;;
  esac
}

# Stamp/refresh the idempotency marker attachment, with a RICH payload.
#
# Linear renders an attachment's `metadata` as a modal with a title + an
# `attributes` list, so the marker stops being a dead link and becomes the
# spec-at-a-glance panel: size, executor, profile, sign-off trust. The `url` is
# the idempotency key and is deliberately synthetic and stable — re-creating an
# attachment with the SAME url updates the existing record rather than adding a
# second, so this is safe to call on every register.
# Fail-soft throughout: a cosmetic panel must never break a registration.
_ln_stamp_marker() {   # _ln_stamp_marker ISSUE_UUID SPEC_ID ATTRS_JSON [spec_url]
  local issue="$1" spec="$2" attrs="${3:-[]}" specurl="${4:-}" murl meta
  murl="$(_ln_marker_url "$spec")"
  meta="$(jq -n --arg spec "$spec" --argjson attrs "$attrs" --arg src "${specurl:-}" \
    '{ specId:$spec, title:"Task-Spec", attributes:$attrs }
     + (if $src == "" then {} else {sourceUrl:$src} end)' 2>/dev/null)" || meta='{}'
  _ln_gql_soft \
    'mutation($issue:String!,$url:String!,$title:String!,$subtitle:String,$meta:JSONObject){ attachmentCreate(input:{ issueId:$issue, url:$url, title:$title, subtitle:$subtitle, metadata:$meta }){ success attachment{ id } } }' \
    "$(jq -n --arg issue "$issue" --arg url "$murl" --arg title "$spec" \
           --arg subtitle "Task-Spec · projected by cvg register" --argjson meta "$meta" \
      '{issue:$issue,url:$url,title:$title,subtitle:$subtitle,meta:$meta}')"
  return 0
}

# Set a due date, fail-soft and ISOLATED in its own call. `dueDate` is a
# TimelessDate scalar; keeping it out of the main create/update mutation means a
# scalar-type surprise can never take a whole registration down with it.
_ln_set_due() {   # _ln_set_due ISSUE_UUID YYYY-MM-DD
  local issue="$1" due="$2"
  [[ -n "$due" && "$due" != "(none)" ]] || return 0
  _ln_gql_soft \
    'mutation($id:String!,$due:TimelessDate){ issueUpdate(id:$id, input:{ dueDate:$due }){ success } }' \
    "$(jq -n --arg id "$issue" --arg due "$due" '{id:$id,due:$due}')"
  return 0
}

# Linear priority is an Int: 0 none, 1 Urgent, 2 High, 3 Medium, 4 Low.
_ln_priority_int() {
  case "$1" in
    P0|p0)          printf '1' ;;
    P1|p1)          printf '2' ;;
    P2|p2)          printf '3' ;;
    P3|p3|P4|p4)    printf '4' ;;
    0|1|2|3|4)      printf '%s' "$1" ;;
    *)              printf '0' ;;
  esac
}

# A stable colour per cvg namespace, so the board reads at a glance.
_ln_label_color() {
  case "$1" in
    cvg)        printf '#5e6ad2' ;;  # indigo — machine-registered marker
    effort:*)   printf '#0f7488' ;;  # teal   — size
    backend:*)  printf '#4cb782' ;;  # green  — which engine
    agent:*)    printf '#f2994a' ;;  # amber  — which role
    severity:*) printf '#eb5757' ;;  # red    — blast radius
    *)          printf '#95a2b3' ;;
  esac
}

# Resolve label NAMES (space-separated) to a JSON array of label ids, creating
# any that don't exist. Echoes `[]` on any failure (fail-soft).
#
# Names are FLAT and colon-namespaced (`effort:S`) — deliberately NOT Linear
# label groups. Groups look like the right fit (they are mutually exclusive, so
# an issue cannot be two sizes), but Linear requires label names to be unique per
# team "no matter if they are nested inside a label group" (linear/linear#428).
# That makes grouping unusable here: a child `feature` under `severity` collides
# with an existing `Feature`, and `claude` under `agent` collides with `claude`
# under `backend` — and because labelIds REPLACES the set, the collision doesn't
# just fail, it DELETES the label off the issue. The colon-prefixed flat form is
# unique by construction and is the workaround Linear's own community settled on.
_ln_label_ids() {
  local names="$1" resp id nm ids=""
  [[ -n "$names" ]] || { printf '[]'; return 0; }
  resp="$(_linear_gql 'query{ issueLabels{ nodes{ id name } } }' '{}')" || { printf '[]'; return 0; }
  for nm in $names; do
    # `[...][0] // empty` rather than `| head -1`: head closes the pipe early and
    # the SIGPIPE would fail the pipeline under `set -o pipefail`.
    id="$(printf '%s' "$resp" | jq -r --arg n "$nm" \
        '[.data.issueLabels.nodes[]? | select(.name==$n) | .id][0] // empty')"
    if [[ -z "$id" ]]; then
      id="$(_linear_gql \
        'mutation($name:String!,$team:String!,$color:String!){ issueLabelCreate(input:{ name:$name, teamId:$team, color:$color }){ success issueLabel{ id } } }' \
        "$(jq -n --arg name "$nm" --arg team "$LINEAR_TEAM_ID" --arg color "$(_ln_label_color "$nm")" \
          '{name:$name,team:$team,color:$color}')" \
        | jq -r '.data.issueLabelCreate.issueLabel.id // empty')" || id=""
    fi
    if [[ -z "$id" ]]; then
      # NEVER silently drop: labelIds REPLACES the set, so an unresolved label
      # would delete itself off the issue. Say so loudly instead.
      echo "WARN (linear adapter): could not resolve label '$nm' — left off the issue" >&2
    else
      ids="${ids}${ids:+ }${id}"
    fi
  done
  [[ -n "$ids" ]] || { printf '[]'; return 0; }
  printf '%s\n' $ids | jq -R . | jq -s -c .
}

# Merge cvg's derived labels into an issue's EXISTING set: keep every label cvg
# does not own (the human's triage), drop stale cvg-owned ones (e.g. a former
# effort:M after the spec was resized), and add the current derived set.
# Echoes a JSON array of label ids; `[]` on any failure (fail-soft).
_ln_merge_label_ids() {   # _ln_merge_label_ids ISSUE_UUID "name name ..."
  local issue="$1" names="$2" resp keep add
  # Ownership is decided by the PARENT GROUP now that cvg's labels are nested:
  # a grouped label's own name is just "S", so matching on "effort:" would treat
  # it as the human's and never replace a stale size. The legacy flat "effort:S"
  # form is still matched so pre-group boards converge on the next register.
  resp="$(_linear_gql 'query($id:String!){ issue(id:$id){ labels{ nodes{ id name parent{ name } } } } }' \
    "$(jq -n --arg id "$issue" '{id:$id}')" 2>/dev/null)" || { printf '[]'; return 0; }
  keep="$(printf '%s' "$resp" | jq -c '
      def owned:
        .name == "cvg"
        or ((.parent.name // "") | IN("effort","backend","agent","severity"))
        or (.name | startswith("effort:") or startswith("backend:")
                    or startswith("agent:") or startswith("severity:"));
      [ .data.issue.labels.nodes[]? | select(owned | not) | .id ]' 2>/dev/null)"
  [[ -n "$keep" ]] || keep='[]'
  add="$(_ln_label_ids "$names")"
  jq -c -n --argjson a "$keep" --argjson b "$add" '($a + $b) | unique' 2>/dev/null || printf '[]'
}

# ---------------------------------------------------------------------------
# VERB: teams — list every team as  key<TAB>name<TAB>uuid  (the setup picker).
# ---------------------------------------------------------------------------
ln_teams() {
  _ln_require_tools
  _linear_resolve_key
  [[ -n "${LINEAR_API_KEY:-}" ]] || tsi_ln_die "LINEAR_API_KEY unset"
  local resp
  resp="$(_linear_gql 'query{ teams{ nodes{ key name id } } }' '{}')"
  printf '%s' "$resp" | jq -r '.data.teams.nodes[]? | "\(.key)\t\(.name)\t\(.id)"'
}

# ---------------------------------------------------------------------------
# VERB: users — list workspace identities as id<TAB>name<TAB>email.
# ---------------------------------------------------------------------------
# Backs `cvg setup identity --list`: the human maps an
# execution_backend/agent choice to one of these identities. Read-only; never
# writes. Empty email prints blank.
ln_users() {
  _ln_require_tools
  _linear_resolve_key
  [[ -n "${LINEAR_API_KEY:-}" ]] || tsi_ln_die "LINEAR_API_KEY unset"
  local resp
  resp="$(_linear_gql 'query{ users(filter:{ active:{ eq:true } }){ nodes{ id name email } } }' '{}')"
  printf '%s' "$resp" | jq -r '.data.users.nodes[]? | "\(.id)\t\(.name)\t\(.email // "")"'
}

# ---------------------------------------------------------------------------
# VERB: preflight — key present AND the team resolves (a live auth check).
# ---------------------------------------------------------------------------
ln_preflight() {
  _ln_require_tools
  _linear_resolve_key
  if [[ -z "${LINEAR_API_KEY:-}" ]]; then
    echo "preflight failed: LINEAR_API_KEY unset" >&2
    echo "remediation: export LINEAR_API_KEY=lin_api_... (and LINEAR_TEAM_ID), then re-run" >&2
    return 1
  fi
  if [[ -z "${LINEAR_TEAM_ID:-}" ]]; then
    echo "preflight failed: LINEAR_TEAM_ID unset" >&2
    echo "remediation: export LINEAR_TEAM_ID=<team-uuid>, then re-run" >&2
    return 1
  fi
  local resp name
  resp="$(_linear_gql 'query($id:String!){ team(id:$id){ id name } }' \
    "$(jq -n --arg id "$LINEAR_TEAM_ID" '{id:$id}')")" || return 1
  name="$(printf '%s' "$resp" | jq -r '.data.team.name // empty')"
  [[ -n "$name" ]] || { echo "preflight failed: team $LINEAR_TEAM_ID not found" >&2; return 1; }
  echo "preflight ok: linear team '$name'"
  return 0
}

# ---------------------------------------------------------------------------
# Internal: resolve a spec id -> Linear issue node id via externalId.
# Echoes the issue id (empty if not found).
# ---------------------------------------------------------------------------
# The deterministic marker URL that carries a spec id onto a Linear issue.
_ln_marker_url() {
  printf '%s%s' "${TSI_LINEAR_MARKER_BASE:-https://cvg.local/task-spec/}" "$1"
}

# Resolve a spec id -> Linear issue UUID via the marker attachment. Empty if absent.
_ln_find_by_external_id() {
  local ext="$1" resp url
  url="$(_ln_marker_url "$ext")"
  resp="$(_linear_gql \
    'query($url:String!){ attachmentsForURL(url:$url){ nodes{ id issue{ id identifier } } } }' \
    "$(jq -n --arg url "$url" '{url:$url}')")"
  printf '%s' "$resp" | jq -r '.data.attachmentsForURL.nodes[0].issue.id // empty'
}

# ---------------------------------------------------------------------------
# VERB: list-issues — EVERY cvg-registered issue as  extid<TAB>identifier.
# ---------------------------------------------------------------------------
# The bulk reverse of _ln_find_by_external_id: the `cvg` label (added on every
# upsert) is the registered-set filter, and the spec id is recovered from the marker
# ATTACHMENT url (the prefix is stripped). Team-scoped, paged to 250. Read-only.
# Backs verify-registration's 1:1 parity gate (count / orphan / missing). An issue
# that carries the label but no marker attachment (e.g. a human tagged it) is
# skipped — only genuinely-projected issues are counted.
ln_list_issues() {
  _ln_require_tools
  [[ -n "${LINEAR_TEAM_ID:-}" ]] || tsi_ln_die "LINEAR_TEAM_ID unset"
  local base resp
  base="$(_ln_marker_url "")"     # marker url PREFIX (empty id) — ltrimstr it off to recover the spec id
  # $team MUST be ID! — IssueFilter's IDComparator rejects String! and the whole query
  # fails validation (which _linear_gql turns into a hard exit, so the gate saw zero
  # issues). Filter on the TEAM only — the exact shape ln_list_ready proves against the
  # live API — and select the registered set CLIENT-SIDE on the marker attachment, which
  # is the true idempotency key: an issue merely carrying the `cvg` label is not a
  # projection, and a projected issue always carries the marker.
  resp="$(_linear_gql \
    'query($team:ID!){ issues(filter:{ team:{ id:{ eq:$team } } }, first:250){ nodes{ identifier attachments{ nodes{ url } } } pageInfo{ hasNextPage } } }' \
    "$(jq -n --arg team "$LINEAR_TEAM_ID" '{team:$team}')")"
  # A truncated page would under-count and make the 1:1 gate cry "missing". Say so loudly
  # rather than silently reporting a wrong set.
  if printf '%s' "$resp" | jq -e '.data.issues.pageInfo.hasNextPage == true' >/dev/null 2>&1; then
    echo "WARN: >250 issues on this team — list-issues is truncated; the 1:1 gate may under-count" >&2
  fi
  printf '%s' "$resp" | jq -r --arg base "$base" '
    .data.issues.nodes[]?
    | . as $i
    | ( [ $i.attachments.nodes[]?.url | select(startswith($base)) | ltrimstr($base) ][0] // empty ) as $ext
    | select($ext != "")
    | "\($ext)\t\($i.identifier)"
  '
}

# ---------------------------------------------------------------------------
# Isolated, fail-soft setters for OPTIONAL projection fields — each in its OWN
# mutation so a scalar/plan/depth surprise on an optional field can never take a
# whole registration down (mirrors _ln_set_due). Applied AFTER the core
# create/update so the proven title/labels/estimate path is never at risk.
# ---------------------------------------------------------------------------
# _ln_set_parent ISSUE_UUID PARENT_UUID [SORT] — nest ISSUE under PARENT. The
# one-level-deep guard (_ln_parent_depth_ok) is enforced by the CALLER before
# this runs; here it is a fail-soft apply.
_ln_set_parent() {
  local issue="$1" parent="$2" sort="${3:-}" input
  [ -n "$issue" ] && [ -n "$parent" ] || return 0
  input="$(jq -n --arg p "$parent" --arg s "$sort" \
    '{parentId:$p} + (if $s=="" then {} else {subIssueSortOrder:($s|tonumber? // 0)} end)' 2>/dev/null)" || return 0
  _ln_gql_soft \
    'mutation($id:String!,$in:IssueUpdateInput!){ issueUpdate(id:$id, input:$in){ success } }' \
    "$(jq -n --arg id "$issue" --argjson in "$input" '{id:$id,in:$in}')"
  return 0
}

# _ln_set_sla ISSUE_UUID SLA — set slaType in an isolated fail-soft call (a
# paid-plan feature; a rejection must not abort the registration).
_ln_set_sla() {
  local issue="$1" sla="$2"
  [ -n "$issue" ] && [ -n "$sla" ] && [ "$sla" != "(none)" ] || return 0
  _ln_gql_soft \
    'mutation($id:String!,$s:SLADayCountType){ issueUpdate(id:$id, input:{ slaType:$s }){ success } }' \
    "$(jq -n --arg id "$issue" --arg s "$sla" '{id:$id,s:$s}')"
  return 0
}

# _ln_resolve_subscribers "v1 v2 ..." — resolve each value to a user uuid (via the
# native _ln_resolve_user), echo a JSON array (empty []). For the CREATE branch,
# where there is no issue yet to union against.
_ln_resolve_subscribers() {
  local vals="$1" v uid out=""
  for v in $vals; do
    uid="$(_ln_resolve_user "$v" || true)"
    if [ -n "$uid" ]; then out="${out}${out:+ }${uid}"; fi
  done
  [ -n "$out" ] || { printf '[]'; return 0; }
  printf '%s\n' $out | jq -R . | jq -s -c .
}

# _ln_apply_input ISSUE_UUID INPUT_JSON — apply an arbitrary IssueUpdateInput in
# ONE isolated, fail-soft issueUpdate, AFTER the core write. A bad optional field
# (unknown enum, stale id, paid-plan-only) degrades to nothing instead of taking
# the registration down — same contract as _ln_set_due/_ln_set_parent/_ln_set_sla.
# A '{}' / empty input is a no-op. Never returns nonzero.
_ln_apply_input() {
  local issue="$1" input="${2:-}"
  [ -n "$issue" ] || return 0
  [ -n "$input" ] && [ "$input" != "{}" ] || return 0
  _ln_gql_soft \
    'mutation($id:String!,$in:IssueUpdateInput!){ issueUpdate(id:$id, input:$in){ success } }' \
    "$(jq -n --arg id "$issue" --argjson in "$input" '{id:$id,in:$in}')"
  return 0
}

# _ln_apply_parent_guarded ISSUE PARENT_SPEC [SORT] — resolve the parent SPEC id to
# its issue, allow macro → swimlane → task, then fail-soft apply. A fourth
# level is the hard stop. A missing parent is a skip, not a half-write.
_ln_apply_parent_guarded() {
  local issue="$1" pspec="${2:-}" sort="${3:-}" puuid
  [ -n "$issue" ] && [ -n "$pspec" ] || return 0
  puuid="$(_ln_parent_ref "$pspec" 2>/dev/null || true)"
  [ -n "$puuid" ] || return 0   # parent not on the board yet — skip (fail-soft)
  if ! _ln_parent_depth_ok "$puuid"; then
    tsi_ln_die "projection.parent '$pspec' is already a task under a swimlane — the factory tree stops at macro → swimlane → task"
  fi
  _ln_set_parent "$issue" "$puuid" "$sort"
}

# ---------------------------------------------------------------------------
# VERB: upsert --id ID --title T --body-file F [--label L ...]
# ---------------------------------------------------------------------------
# Find-by-externalId then update, else create. Echoes the issue node id.
ln_upsert() {
  _ln_require_tools
  [[ -n "${LINEAR_TEAM_ID:-}" ]] || tsi_ln_die "LINEAR_TEAM_ID unset"
  local id="" title="" body_file="" labels="" prio="" effort="" due="" attrs="" specurl=""
  local assignee="" state="" subscribers="" project="" milestone="" cycle="" parent="" subsort="" template="" usedefault=0 sla=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --id)        id="$2"; shift 2 ;;
      --title)     title="$2"; shift 2 ;;
      --body-file) body_file="$2"; shift 2 ;;
      --label)     labels="${labels}${labels:+ }$2"; shift 2 ;;
      --priority)  prio="$2"; shift 2 ;;
      --effort)    effort="$2"; shift 2 ;;
      --due)       due="$2"; shift 2 ;;
      --attr)      attrs="${attrs}${attrs:+$'\n'}$2"; shift 2 ;;   # "Name=Value"
      --spec-url)  specurl="$2"; shift 2 ;;
      # T1 native fields — assignee/state seed-once, subscribers union-merged:
      --assignee)   assignee="$2"; shift 2 ;;
      --state)      state="$2"; shift 2 ;;
      --subscriber) subscribers="${subscribers}${subscribers:+ }$2"; shift 2 ;;
      # T2 projection: block — placement re-synced; parent is one level deep:
      --project)    project="$2"; shift 2 ;;
      --milestone)  milestone="$2"; shift 2 ;;
      --cycle)      cycle="$2"; shift 2 ;;
      --parent)     parent="$2"; shift 2 ;;
      --sub-sort)   subsort="$2"; shift 2 ;;
      --template)   template="$2"; shift 2 ;;
      --use-default-template) usedefault=1; shift ;;
      --sla)        sla="$2"; shift 2 ;;
      *) tsi_ln_die "upsert: unknown arg '$1'" ;;
    esac
  done
  # template / use_default_template are ACCEPTED for projection portability but NOT
  # yet applied on Linear: a templateId must be set at issueCreate time and needs a
  # name→id resolver this tier does not ship. Note it once (never silently drop) so a
  # spec author knows the field was a no-op here — same honesty as the github/jira
  # degrade. Referencing them here also keeps them from reading as dead locals.
  if [ -n "$template" ] || [ "$usedefault" -eq 1 ]; then
    echo "note: projection 'template' is accepted but not yet applied on the linear backend (deferred — no template resolver)" >&2
  fi
  # Build the rich-marker attribute list once: [{name,value}, …] for Linear's modal.
  local attrs_json
  attrs_json="$(printf '%s' "$attrs" | jq -R -s -c \
    'split("\n") | map(select(length>0)) | map(split("=") | {name: .[0], value: (.[1:] | join("="))})' 2>/dev/null)" || attrs_json='[]'
  [[ -n "$attrs_json" ]] || attrs_json='[]'
  # estimate is DERIVED from the spec, so (like labels) it re-syncs on every
  # register. `null` leaves the field unset rather than forcing a zero.
  local est estj
  est="$(_ln_estimate_points "$effort")"
  estj="${est:-null}"
  [[ -n "$id" ]]        || tsi_ln_die "upsert: --id required"
  [[ -n "$title" ]]     || tsi_ln_die "upsert: --title required"
  [[ -f "$body_file" ]] || tsi_ln_die "upsert: --body-file '$body_file' not readable"

  local body existing
  body="$(cat "$body_file")"
  existing="$(_ln_find_by_external_id "$id" || true)"

  # stdout returns the HUMAN identifier (e.g. ENG-42) when available so the
  # register report and the tracker_ref receipt read cleanly (`linear:ENG-42`),
  # falling back to the node id. Link resolution never depends on this value — it
  # re-resolves by externalId — so returning the identifier is safe.
  if [[ -n "$existing" ]]; then
    local uresp ident ulabels
    # Derived labels are part of the projection, so they re-sync on every update —
    # merged so the human's own labels survive untouched. Priority is NOT sent:
    # that is the board's triage to own.
    ulabels="$(_ln_merge_label_ids "$existing" "$labels")"
    uresp="$(_linear_gql \
      'mutation($id:String!,$title:String!,$desc:String!,$labels:[String!],$est:Int){ issueUpdate(id:$id, input:{ title:$title, description:$desc, labelIds:$labels, estimate:$est }){ success issue{ id identifier } } }' \
      "$(jq -n --arg id "$existing" --arg title "$title" --arg desc "$body" --argjson labels "$ulabels" --argjson est "$estj" \
        '{id:$id,title:$title,desc:$desc,labels:$labels,est:$est}')")"
    ident="$(printf '%s' "$uresp" | jq -r '.data.issueUpdate.issue.identifier // empty')"
    ident="${ident:-$existing}"
    _ln_set_due "$existing" "$due"
    # Refresh the marker so its panel tracks the spec (same url ⇒ update, not a dupe).
    _ln_stamp_marker "$existing" "$id" "$attrs_json" "$specurl"
    # Re-synced projection on UPDATE: placement (project/milestone/cycle) tracks the
    # spec, and subscribers UNION-merge so a human's own subscriber is never dropped.
    # assignee/state/priority are NOT re-sent — they are seed-once, the board owns
    # them after create. Applied via the isolated fail-soft applier, never the core.
    local u_subs="[]" u_cyc u_input
    [ -n "$subscribers" ] && u_subs="$(_ln_merge_subscribers "$existing" "$subscribers" 2>/dev/null || printf '[]')"
    u_cyc="$(_ln_cycle_id "$cycle" 2>/dev/null || true)"
    u_input="$(jq -n --argjson subs "${u_subs:-[]}" --arg proj "$project" --arg mile "$milestone" --arg cyc "$u_cyc" '
      {}
      + (if ($subs|length) > 0 then {subscriberIds:$subs} else {} end)
      + (if $proj != "" then {projectId:$proj}          else {} end)
      + (if $mile != "" then {projectMilestoneId:$mile} else {} end)
      + (if $cyc  != "" then {cycleId:$cyc}             else {} end)
    ' 2>/dev/null)" || u_input="{}"
    _ln_apply_input "$existing" "$u_input"
    _ln_apply_parent_guarded "$existing" "$parent" "$subsort"
    _ln_set_sla "$existing" "$sla"
    echo "updated $ident ($id)" >&2
    echo "$ident"
  else
    local resp new new_uuid new_ident pint lids
    # Triage is seeded ONCE, at create. A re-register never touches priority or
    # labels again, so a human's triage on the board is never clobbered.
    pint="$(_ln_priority_int "${prio:-}")"
    lids="$(_ln_label_ids "$labels")"
    resp="$(_linear_gql \
      'mutation($team:String!,$title:String!,$desc:String!,$prio:Int,$labels:[String!],$est:Int){ issueCreate(input:{ teamId:$team, title:$title, description:$desc, priority:$prio, labelIds:$labels, estimate:$est }){ success issue{ id identifier } } }' \
      "$(jq -n --arg team "$LINEAR_TEAM_ID" --arg title "$title" --arg desc "$body" \
             --argjson prio "$pint" --argjson labels "$lids" --argjson est "$estj" \
        '{team:$team,title:$title,desc:$desc,prio:$prio,labels:$labels,est:$est}')")"
    new_uuid="$(printf '%s' "$resp" | jq -r '.data.issueCreate.issue.id // empty')"
    new_ident="$(printf '%s' "$resp" | jq -r '.data.issueCreate.issue.identifier // empty')"
    [[ -n "$new_uuid" ]] || tsi_ln_die "issueCreate returned no issue id for $id"
    # Stamp the idempotency marker so the NEXT run RESOLVES this issue instead of
    # creating a second one. Without this attachment the projection is not idempotent.
    _ln_set_due "$new_uuid" "$due"
    _ln_stamp_marker "$new_uuid" "$id" "$attrs_json" "$specurl"
    # Optional projection enrichment — applied AFTER the proven create, each in an
    # isolated fail-soft mutation so a surprise on an optional field never aborts a
    # registration. assignee + state are SEED-ONCE (create only); subscribers seed
    # fresh here (nothing to union yet). project/milestone arrive as resolved UUIDs
    # from the driver's structure pre-pass; cycle resolves here from a human ref.
    local c_ass c_state c_subs="[]" c_cyc c_input
    c_ass="$(_ln_resolve_user "$(_ln_identity_lookup "$assignee")" 2>/dev/null || true)"
    c_state="$(_ln_state_id "$state" 2>/dev/null || true)"
    [ -n "$subscribers" ] && c_subs="$(_ln_resolve_subscribers "$subscribers" 2>/dev/null || printf '[]')"
    c_cyc="$(_ln_cycle_id "$cycle" 2>/dev/null || true)"
    c_input="$(jq -n --arg ass "$c_ass" --arg st "$c_state" --argjson subs "${c_subs:-[]}" \
                     --arg proj "$project" --arg mile "$milestone" --arg cyc "$c_cyc" '
      {}
      + (if $ass  != "" then {assigneeId:$ass}          else {} end)
      + (if $st   != "" then {stateId:$st}              else {} end)
      + (if ($subs|length) > 0 then {subscriberIds:$subs} else {} end)
      + (if $proj != "" then {projectId:$proj}          else {} end)
      + (if $mile != "" then {projectMilestoneId:$mile} else {} end)
      + (if $cyc  != "" then {cycleId:$cyc}             else {} end)
    ' 2>/dev/null)" || c_input="{}"
    _ln_apply_input "$new_uuid" "$c_input"
    _ln_apply_parent_guarded "$new_uuid" "$parent" "$subsort"
    _ln_set_sla "$new_uuid" "$sla"
    new="${new_ident:-$new_uuid}"
    echo "created $new ($id)" >&2
    echo "$new"
  fi
}

# ---------------------------------------------------------------------------
# VERB: link --from ID --to ID
# ---------------------------------------------------------------------------
# depends_on(FROM -> TO) becomes: TO `blocks` FROM (Linear surfaces this as FROM
# "blocked by" TO). Idempotent because Linear dedupes identical relations.
ln_link() {
  _ln_require_tools
  local from_id="" to_id=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --from) from_id="$2"; shift 2 ;;
      --to)   to_id="$2"; shift 2 ;;
      *) tsi_ln_die "link: unknown arg '$1'" ;;
    esac
  done
  [[ -n "$from_id" && -n "$to_id" ]] || tsi_ln_die "link: --from and --to required"

  local from to
  from="$(_ln_find_by_external_id "$from_id" || true)"
  to="$(_ln_find_by_external_id "$to_id" || true)"
  [[ -n "$from" ]] || tsi_ln_die "link: from-issue not found for $from_id"
  [[ -n "$to" ]]   || tsi_ln_die "blocked-by target not found for $to_id"

  # issueId=$to blocks relatedIssueId=$from  →  $from is "blocked by" $to.
  _linear_gql \
    'mutation($issue:String!,$related:String!){ issueRelationCreate(input:{ issueId:$issue, relatedIssueId:$related, type:blocks }){ success } }' \
    "$(jq -n --arg issue "$to" --arg related "$from" '{issue:$issue,related:$related}')" >/dev/null
  echo "linked: $from_id blocked-by $to_id" >&2
}

# ---------------------------------------------------------------------------
# VERB: list-ready — issues with no OPEN `blocks` relation pointing at them.
# ---------------------------------------------------------------------------
# Pulls the team's registered issues with their inverse relations; an issue is
# ready when none of the issues that block it is still incomplete. Echoes
# identifiers (e.g. ENG-42), one per line.
ln_list_ready() {
  _ln_require_tools
  [[ -n "${LINEAR_TEAM_ID:-}" ]] || tsi_ln_die "LINEAR_TEAM_ID unset"
  local resp
  # NB: IssueFilter cannot cheaply filter on our marker attachment, so this returns
  # the TEAM's takeable frontier (incomplete + no open blocker) rather than only
  # registered issues. That is what the loop wants; a human-made issue on the same
  # team will also appear.
  resp="$(_linear_gql \
    'query($team:ID!){ issues(filter:{ team:{ id:{ eq:$team } } }){ nodes{ identifier state{ type } inverseRelations{ nodes{ type issue{ state{ type } } } } } } }' \
    "$(jq -n --arg team "$LINEAR_TEAM_ID" '{team:$team}')")"
  # ready = not completed/canceled AND no incoming `blocks` from an unfinished issue.
  printf '%s' "$resp" | jq -r '
    .data.issues.nodes[]
    | select(.state.type != "completed" and .state.type != "canceled")
    | select(
        [ .inverseRelations.nodes[]?
          | select(.type == "blocks")
          | .issue.state.type
          | select(. != "completed" and . != "canceled")
        ] | length == 0
      )
    | .identifier'
}

# ---------------------------------------------------------------------------
# VERB: write-result --issue ID --status pass|fail [--pr URL] [--reason TEXT]
# ---------------------------------------------------------------------------
# The LOOP's write side (Pass 8), not registration. Comments on the issue; on a
# pass, moves it to the team's first `completed`-type state.
ln_write_result() {
  _ln_require_tools
  local issue="" status="" pr="" reason=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --issue)  issue="$2"; shift 2 ;;
      --status) status="$2"; shift 2 ;;
      --pr)     pr="$2"; shift 2 ;;
      --reason) reason="$2"; shift 2 ;;
      *) tsi_ln_die "write-result: unknown arg '$1'" ;;
    esac
  done
  [[ -n "$issue" ]] || tsi_ln_die "write-result: --issue required"
  case "$status" in pass|fail) ;; *) tsi_ln_die "write-result: --status must be pass|fail" ;; esac

  local node
  node="$(_ln_find_by_external_id "$issue" || true)"
  [[ -n "$node" ]] || node="$issue"  # accept a raw node id too

  local comment
  if [[ "$status" == "pass" ]]; then
    comment="eval GREEN — done.${pr:+ PR: $pr}"
  else
    comment="eval RED — parked.${reason:+ reason: $reason}"
  fi
  _linear_gql \
    'mutation($id:String!,$body:String!){ commentCreate(input:{ issueId:$id, body:$body }){ success } }' \
    "$(jq -n --arg id "$node" --arg body "$comment" '{id:$id,body:$body}')" >/dev/null

  if [[ "$status" == "pass" ]]; then
    local st
    # `team(id:)` is a ROOT field and takes String!; only `IssueFilter.team.id.eq`
    # takes ID!. Both spellings live in this file (382/664 vs 42 in
    # linear-projection.sh) and this call had the wrong one, so the first live
    # write-result died with `Variable "$team" of type "ID!" used in position
    # expecting type "String!"`. It survived every offline suite because the fake
    # adapter has no schema — and it survived every real run because the loop
    # settles LOCAL_SETTLED unless --allow-external-writes is passed, so Pass 8's
    # board-write leg had never once executed against Linear.
    st="$(_linear_gql \
      'query($team:String!){ team(id:$team){ states(filter:{ type:{ eq:"completed" } }){ nodes{ id } } } }' \
      "$(jq -n --arg team "$LINEAR_TEAM_ID" '{team:$team}')" \
      | jq -r '.data.team.states.nodes[0].id // empty')"
    if [[ -n "$st" ]]; then
      _linear_gql \
        'mutation($id:String!,$state:String!){ issueUpdate(id:$id, input:{ stateId:$state }){ success } }' \
        "$(jq -n --arg id "$node" --arg state "$st" '{id:$id,state:$state}')" >/dev/null
    fi
    echo "completed $issue (pass)"
  else
    echo "commented $issue (fail)"
  fi
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Tier companions — function-only files sourced behind an existence guard, AFTER
# the core transport + verbs above (so each may lean on _linear_gql / tsi_ln_die /
# _ln_is_uuid / _ln_find_by_external_id) and BEFORE dispatch below. They add ONLY
# functions — no dispatch, no network at source time. The T4 agents file that ships
# as `.scaffold` is deliberately NOT here: it stays dark until promoted (see
# references/agents-api-scaffold.md).
# ---------------------------------------------------------------------------
[ -f "$_LN_DIR/linear-native.sh" ]     && . "$_LN_DIR/linear-native.sh"
[ -f "$_LN_DIR/linear-projection.sh" ] && . "$_LN_DIR/linear-projection.sh"
[ -f "$_LN_DIR/linear-structure.sh" ]  && . "$_LN_DIR/linear-structure.sh"

_ln_main() {
  local verb="${1:-}"
  [[ $# -gt 0 ]] && shift || true
  # Resolve a team KEY (e.g. CVG) to its UUID for the verbs that need a team, so a
  # human can pass the key straight from the Linear URL. A UUID passes through.
  case "$verb" in
    preflight|upsert|link|list-ready|list-issues|write-result|users|project-ensure|milestone-ensure|initiative-ensure|project-update|document)
      if [[ -n "${LINEAR_TEAM_ID:-}" ]] && ! _ln_is_uuid "$LINEAR_TEAM_ID"; then
        local _r; _r="$(_ln_resolve_team_id 2>/dev/null || true)"
        [[ -n "$_r" ]] && LINEAR_TEAM_ID="$_r"
      fi
      ;;
  esac
  case "$verb" in
    preflight)    ln_preflight "$@" ;;
    upsert)       ln_upsert "$@" ;;
    link)         ln_link "$@" ;;
    list-ready)   ln_list_ready "$@" ;;
    list-issues)  ln_list_issues "$@" ;;
    write-result) ln_write_result "$@" ;;
    teams)        ln_teams "$@" ;;
    resolve-team) _ln_resolve_team_id ;;
    users)             ln_users "$@" ;;
    project-ensure)    ln_project_ensure "$@" ;;
    milestone-ensure)  ln_milestone_ensure "$@" ;;
    initiative-ensure) ln_initiative_ensure "$@" ;;
    project-update)    ln_project_update "$@" ;;
    document)          ln_document "$@" ;;
    ""|-h|--help)
      grep -E '^#( |$)' "$0" | sed -E 's/^# ?//'
      ;;
    *) tsi_ln_die "unknown verb '$verb' (want: preflight|upsert|link|list-ready|list-issues|write-result|teams|resolve-team|users|project-ensure|milestone-ensure|initiative-ensure|project-update|document)" ;;
  esac
}

_ln_main "$@"
