#!/usr/bin/env python3
"""raknet_hr.py — human-readable ENCODER for decoded RakNet/Stormancer payloads.

Consumes the data-only lookup tables in raknet_tables.py to turn a fully-literal
decoded msgpack value (as produced by raknet._RelayAssert._literal /
_skel_or_binary) into a single deterministic, symbol-free, abbreviated string.

Contract (see raknet-dictionary.md §9):
  * No JSON structural symbols: none of  {}[]":,  ever appears in the output.
  * Deterministic: identical input -> identical string (maps key-sorted, arrays
    in order). Therefore any difference between two hr strings implies a real
    difference in the underlying decoded value (and thus the raw hex).
  * Identity (session ids, tokens, user ids, names) shown verbatim; only opaque
    blobs longer than HR_OPAQUE_MAX are shortened to '<first16>~<len>' (length is
    preserved, so a length change still shows).
  * Allocation noise (SceneHandle) is normalized to '*' — the ONLY value hidden,
    applied symmetrically to real and pred.

The same functions render both the real and the predicted side, so the
comparison stays apples-to-apples.
"""
import raknet_tables as T


# Characters that must never appear in hr output; replaced by a space in any
# verbatim content string so two differently-symboled strings can still diverge
# via their surrounding characters / length (comparison is hex-primary anyway).
_FORBIDDEN = str.maketrans({c: " " for c in T.HR_FORBIDDEN_SYMBOLS})


def _clean(s):
    """Strip forbidden structural symbols from a content string."""
    return s.translate(_FORBIDDEN)


def _opaque(s):
    """Render a string with the identity/opaque rule: verbatim if short, else
    '<first16>~<len>' so prefix + length still surface a change."""
    if len(s) > T.HR_OPAQUE_MAX:
        return "%s~%d" % (_clean(s[:T.HR_OPAQUE_TRUNC]), len(s))
    return _clean(s)


def abbr_kind(kind):
    """Scene-kind -> short tag (auth, frnd, pty, mm, gs, ...)."""
    return T.SCENE_KIND_ABBR.get(kind, kind)


def abbr_route(kind, rname):
    """Route name -> abbreviation. Tries the kind-specific table first, then the
    flat union, then falls back to the (cleaned, lowercased) name or 'r#N'."""
    tbl = T.ROUTE_ABBR_BY_KIND.get(kind)
    if tbl and rname in tbl:
        return tbl[rname]
    if rname in T.ROUTE_ABBR_ALL:
        return T.ROUTE_ABBR_ALL[rname]
    return _clean(rname)


def _is_bin(d):
    return isinstance(d, dict) and (
        ("hex" in d and "len" in d and len(d) == 2)
        or ("bin_hex" in d and "len" in d and len(d) == 2))


def _is_ext(d):
    return isinstance(d, dict) and "ext" in d and "hex" in d and len(d) == 2


def _hr_bin(d):
    hx = d.get("bin_hex", d.get("hex", ""))
    return "%s%d_%s" % (T.HR_BIN_PREFIX, d.get("len", len(hx) // 2), hx[:16])


def _hr_ext(d):
    return "%s%s_%s" % (T.HR_EXT_PREFIX, d.get("ext"), str(d.get("hex"))[:16])


def hr_value(v):
    """Recursively render any literal-decoded value, symbol-free.

    Containers are length-prefixed (l<n> for arrays, m<n> for maps) and use
    spaces instead of brackets/commas, so the structure is unambiguous and
    deterministic without any forbidden symbol."""
    if v is None:
        return T.HR_NIL
    if isinstance(v, bool):
        return T.HR_BOOL_TRUE if v else T.HR_BOOL_FALSE
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        return repr(v)
    if isinstance(v, str):
        return _opaque(v)
    if isinstance(v, dict):
        if _is_bin(v):
            return _hr_bin(v)
        if _is_ext(v):
            return _hr_ext(v)
        if "ERR" in v:
            return "err_%s" % _clean(str(v.get("ERR")))
        return hr_map(v)
    if isinstance(v, (list, tuple)):
        return hr_list(v)
    return _clean(str(v))


def hr_map(d):
    """Render a map as 'm<n> k=val k=val ...' with keys sorted. Noise keys are
    normalized to '*'; everything else (identity included) is shown."""
    items = []
    for k in sorted(d.keys(), key=str):
        ks = _clean(str(k))
        if k in T.NOISE_KEYS:
            items.append("%s=%s" % (ks, T.HR_WILDCARD))
        else:
            items.append("%s=%s" % (ks, hr_value(d[k])))
    return "m%d %s" % (len(items), " ".join(items)) if items else "m0"


def hr_list(seq):
    """Render an array as 'l<n> v0 v1 ...' in order."""
    if not seq:
        return "l0"
    return "l%d %s" % (len(seq), " ".join(hr_value(x) for x in seq))


# =========================================================================
# Schema collapses (§8) — recognise a known structure and emit only the
# field(s) that actually vary, keeping the output compact.
# =========================================================================
def _route_mappings(rm):
    """Render a RouteMappings map as 'name:handle' pairs sorted by name."""
    if not isinstance(rm, dict):
        return hr_value(rm)
    pairs = ["%s=%s" % (_clean(str(n)), hr_value(h))
             for n, h in sorted(rm.items(), key=lambda kv: str(kv[0]))]
    return " ".join(pairs)


def hr_connres(first):
    """ConnectionResult {SceneHandle, RouteMappings, ...} -> 'connres h=* rm ...'.
    The SceneHandle scalar is allocation noise (normalized to '*'); the route
    name->handle assignment WITHIN the scene is kept (it is real)."""
    rm = first.get("RouteMappings")
    return "connres h=%s rm %s" % (T.HR_WILDCARD, _route_mappings(rm))


def hr_mergerstatus(v):
    """PartyMerging.GetMergerStatus reply -> 'mergerstatus parties=N players=M'.
    Digs for the {partiesCount, playersCount} map anywhere in the structure."""
    found = _find_map_with(v, ("partiesCount", "playersCount"))
    if found is None:
        return None
    return "mergerstatus parties=%s players=%s" % (
        hr_value(found.get("partiesCount")), hr_value(found.get("playersCount")))


def _find_map_with(v, keys):
    """Depth-first search for the first dict containing all `keys`."""
    if isinstance(v, dict):
        if all(k in v for k in keys):
            return v
        for val in v.values():
            r = _find_map_with(val, keys)
            if r is not None:
                return r
    elif isinstance(v, (list, tuple)):
        for x in v:
            r = _find_map_with(x, keys)
            if r is not None:
                return r
    return None


def hr_payload(lit, route_abbr=None):
    """Top-level render of a decoded payload value `lit` (list of values, a map,
    or a bin/ext dict). Applies schema collapses when the shape is recognised,
    otherwise falls back to the generic symbol-free renderer."""
    # ConnectionResult: a list whose first element carries SceneHandle+RouteMappings.
    if (isinstance(lit, list) and lit and isinstance(lit[0], dict)
            and "SceneHandle" in lit[0] and "RouteMappings" in lit[0]):
        return hr_connres(lit[0])
    # Merger status (matchmaking rnext / GetMergerStatus reply).
    if route_abbr in ("mergerstatus", "rnext", "gfupd"):
        ms = hr_mergerstatus(lit)
        if ms is not None:
            return ms
    return hr_value(lit)
