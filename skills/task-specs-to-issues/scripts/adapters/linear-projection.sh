#!/usr/bin/env bash
# adapters/linear-projection.sh — T2 projection-block resolvers for the Linear
# backend. FUNCTION-ONLY: this file defines helpers and nothing else. It is
# SOURCED by adapters/linear.sh (behind an existence guard) AFTER the core
# helpers are defined and BEFORE _ln_main, so it may freely rely on:
#   _linear_gql, tsi_ln_die, _ln_find_by_external_id, LINEAR_TEAM_ID
# (the parent's _ln_find_by_external_id encapsulates the marker-URL construction,
# so this file never touches _ln_marker_url directly.)
# It intentionally does NOT `set -euo pipefail` (linear.sh already did, and a
# sourced companion must not carry global side effects), defines no verbs, and is
# never added to dispatch. curl/jq are guaranteed present: every verb that calls
# these has already run _ln_require_tools.
#
# The three resolvers here back the `projection:` frontmatter block (see
# references/projection-block.md): cycle placement, parent nesting, and the
# one-level-deep depth guard Linear enforces on sub-issues. Each is READ-ONLY and
# FAIL-SOFT — an unresolved optional field echoes empty so the caller can retry
# the mutation without it, exactly like _ln_set_due / _ln_label_ids upstream. The
# ONE deliberate hard stop (a parent that is itself a sub-issue) is surfaced by
# _ln_parent_depth_ok returning nonzero; the caller — never this file — decides to
# tsi_ln_die on it, so there is never a half-written issue.

# ---------------------------------------------------------------------------
# _ln_cycle_id NAME_OR_UUID — resolve a cycle to its UUID, SCOPED TO THE TEAM.
# ---------------------------------------------------------------------------
# Echoes the cycle UUID, or empty if it does not resolve to a cycle on this team
# (which is exactly the "must belong to team" guarantee: the match is drawn only
# from LINEAR_TEAM_ID's own cycles, so a UUID from another team echoes empty).
# Accepts three human forms, all matched case-insensitively against the team's
# cycles:  a UUID (verified for membership), an explicit `name`, or a number —
# bare (`7`) or spelled (`Cycle 7`) — since most Linear cycles are unnamed and
# addressed by their sequence number. Fail-soft: any transport/parse failure
# echoes empty and returns 0, so an unresolved cycle is simply omitted.
_ln_cycle_id() {
  local ref="$1" resp
  [ -n "$ref" ] || { printf ''; return 0; }
  [ -n "${LINEAR_TEAM_ID:-}" ] || { printf ''; return 0; }
  # first:250 covers ~5 years of weekly cycles in a single call; cycles are the
  # one Linear structure whose count grows unbounded with time, so unlike the
  # states/labels queries this one is explicitly paged.
  resp="$(_linear_gql \
    'query($team:String!){ team(id:$team){ cycles(first:250){ nodes{ id name number } } } }' \
    "$(jq -n --arg team "$LINEAR_TEAM_ID" '{team:$team}')" 2>/dev/null)" || { printf ''; return 0; }
  printf '%s' "$resp" | jq -r --arg ref "$ref" '
    ( $ref | ascii_downcase ) as $r
    | ( $r | gsub("[^0-9]"; "") ) as $num
    | [ .data.team.cycles.nodes[]?
        | select(
            (.id == $ref)
            or (((.name // "") | ascii_downcase) == $r)
            or ( ($r | test("^(cycle[[:space:]]*)?[0-9]+$"))
                 and ((.number | tostring) == $num) )
          )
        | .id
      ][0] // empty
  ' 2>/dev/null || printf ''
}

# ---------------------------------------------------------------------------
# _ln_parent_ref SPEC_ID — resolve a parent SPEC id to its Linear issue UUID.
# ---------------------------------------------------------------------------
# The parent is named in the child's `projection.parent` by its SPEC id, so it is
# resolved through the SAME idempotency marker that identifies every projected
# issue (_ln_find_by_external_id). Echoes the UUID, or empty when the parent has
# not been registered yet (a not-yet-created parent is a fail-soft skip, not an
# error — a transport error still propagates, consistent with the rest of the
# adapter). Register upserts in build order, so a declared parent is normally
# already on the board by the time its child is projected.
_ln_parent_ref() {
  local spec="$1"
  [ -n "$spec" ] || { printf ''; return 0; }
  _ln_find_by_external_id "$spec"
}

# ---------------------------------------------------------------------------
# _ln_parent_depth_ok PARENT_UUID — allow macro, swimlane, then task.
# ---------------------------------------------------------------------------
# The factory tree is three issue levels. A parent may have a parent. It may
# not have a grandparent. Returns 0 when nesting under PARENT stays within
# those two hops. Fail-soft on an unverifiable read.
_ln_parent_depth_ok() {
  local parent="$1" resp grand
  [ -n "$parent" ] || return 0
  resp="$(_linear_gql \
    'query($id:String!){ issue(id:$id){ parent{ parent{ id } } } }' \
    "$(jq -n --arg id "$parent" '{id:$id}')" 2>/dev/null)" || return 0
  grand="$(printf '%s' "$resp" | jq -r '.data.issue.parent.parent.id // empty' 2>/dev/null || printf '')"
  [ -z "$grand" ]
}
