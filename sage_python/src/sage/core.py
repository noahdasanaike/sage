"""Core retrieval functions for SAGE.

The SAGE release is shipped as a hive-partitioned Parquet dataset, e.g.:

    <source>/
      country=Afghanistan/year=2014/part-0.parquet
      country=Afghanistan/year=2019/part-0.parquet
      country=Albania/year=2009/part-0.parquet
      ...
      _index.csv

The ``source`` can be:

- a local path: ``"J:/Output_c_parquet"``
- a Google Cloud Storage URI: ``"gs://sage-archive/parquet"``
- an S3 URI: ``"s3://sage-archive/parquet"``
- an HTTPS URL pointing at a GCS/S3 bucket with public anonymous access

Resolution order:
    1. value most recently passed to :func:`set_source`
    2. the ``SAGE_SOURCE`` environment variable
    3. the local development default ``J:/Output_c_parquet``
"""
from __future__ import annotations

import os
from typing import Iterable, Optional, Sequence

import pyarrow.dataset as ds
import pyarrow.parquet as pq
import pyarrow as pa
import pandas as pd

_SOURCE: Optional[str] = None
_DEFAULT_SOURCE = "gs://sage-archive/parquet"

_CONFIDENCE_LEVELS = {
    "high":   ("high",),
    "medium": ("high", "medium"),
    "low":    ("high", "medium", "low"),
}


def set_source(source: str) -> str:
    """Override the current SAGE source URI/path."""
    global _SOURCE
    _SOURCE = source
    return source


def get_source() -> str:
    if _SOURCE is not None:
        return _SOURCE
    env = os.environ.get("SAGE_SOURCE")
    if env:
        return env
    return _DEFAULT_SOURCE


def _open_dataset() -> ds.Dataset:
    src = get_source()
    partitioning = ds.partitioning(
        pa.schema([("country", pa.string()), ("year", pa.int32())]),
        flavor="hive",
    )
    # Anonymous gs:// reads need an explicit GcsFileSystem with anonymous=True;
    # passing a bare gs:// URI to ds.dataset() tries to authenticate and fails
    # on a public bucket if the user has no GCP creds.
    if src.startswith("gs://"):
        from pyarrow import fs
        rest = src[len("gs://"):]
        bucket, _, path = rest.partition("/")
        gcs = fs.GcsFileSystem(anonymous=True)
        target = f"{bucket}/{path}" if path else bucket
        return ds.dataset(target, filesystem=gcs,
                          format="parquet", partitioning=partitioning)
    return ds.dataset(src, format="parquet", partitioning=partitioning)


def _read_index() -> "pd.DataFrame | None":
    """Read the lightweight `_index.csv` partition list shipped with the
    release. Avoids walking every partition over the network just to list
    countries/years. Returns None if the index isn't reachable."""
    import time
    src = get_source()
    if src.startswith("gs://"):
        # ?ts=... busts the GCS edge cache so users always see the
        # current index even when it was just regenerated upstream.
        url = ("https://storage.googleapis.com/" + src[len("gs://"):]
               + "/_index.csv?ts=" + str(int(time.time())))
    elif src.startswith("https://") or src.startswith("http://"):
        url = src.rstrip("/") + "/_index.csv"
    else:
        local = src + "/_index.csv"
        try:
            return pd.read_csv(local)
        except Exception:
            return None
    try:
        return pd.read_csv(url)
    except Exception:
        return None


def sage_countries() -> list[str]:
    """Return the sorted list of countries available in the current source."""
    idx = _read_index()
    if idx is not None and "country" in idx.columns:
        return sorted(set(idx["country"].astype(str)))
    # Fallback: walk the dataset (slow on remote storage).
    table = _open_dataset().to_table(columns=["country"])
    return sorted(set(table.column("country").to_pylist()))


def sage_years(country: str) -> list[int]:
    """Return the sorted list of election years for the named country."""
    idx = _read_index()
    if idx is not None and {"country", "year"}.issubset(idx.columns):
        sub = idx[idx["country"] == country]
        return sorted(set(int(y) for y in sub["year"]))
    flt = ds.field("country") == country
    table = _open_dataset().to_table(columns=["year"], filter=flt)
    return sorted(set(int(y) for y in table.column("year").to_pylist()))


def sage_columns() -> list[str]:
    """Return all column names exposed by the dataset (including the
    partition columns ``country`` and ``year``)."""
    return list(_open_dataset().schema.names)


def sage_load(
    country: str,
    years: Optional[Iterable[int]] = None,
    columns: Optional[Sequence[str]] = None,
    election_type: Optional[str | Iterable[str]] = None,
    min_match_confidence: Optional[str] = None,
    drop_all_na: bool = True,
) -> pd.DataFrame:
    """Load a (country, years, columns) slice of SAGE as a pandas DataFrame.

    Parameters
    ----------
    country : str
        Single country name (e.g., ``"Germany"``).
    years : iterable of int, optional
        Filter by election year. ``None`` keeps all years.
    columns : sequence of str, optional
        Subset of columns to return. ``None`` returns all columns.
        ``country`` and ``year`` are always included.
    election_type : str or iterable of str, optional
        Filter on the ``election_type`` column.
    min_match_confidence : {"high", "medium", "low"}, optional
        Restrict to rows whose ``match_confidence`` is at least this strict.
    drop_all_na : bool, default True
        Drop columns that are entirely NA for this country slice. Without
        this, Arrow's union schema across the hive-partitioned dataset
        surfaces every column that any partition carries (so an Iceland
        slice would carry ``NAME4`` from Brazil as a wholly-NA column).
        Set to ``False`` to preserve the full union schema.
    """
    if not isinstance(country, str):
        raise TypeError("country must be a single string")

    flt = ds.field("country") == country
    if years is not None:
        years = list(years)
        flt = flt & ds.field("year").isin([int(y) for y in years])
    if election_type is not None:
        if isinstance(election_type, str):
            flt = flt & (ds.field("election_type") == election_type)
        else:
            flt = flt & ds.field("election_type").isin(list(election_type))
    if min_match_confidence is not None:
        if min_match_confidence not in _CONFIDENCE_LEVELS:
            raise ValueError(
                "min_match_confidence must be one of 'high', 'medium', 'low'"
            )
        flt = flt & ds.field("match_confidence").isin(
            list(_CONFIDENCE_LEVELS[min_match_confidence])
        )

    cols = None
    if columns is not None:
        cols = list({"country", "year", *columns})

    table = _open_dataset().to_table(columns=cols, filter=flt)
    df = table.to_pandas()
    if drop_all_na and len(df):
        df = df.dropna(axis="columns", how="all")
    # Reorder so partition columns come first; arrow's hive layout puts
    # them at the end on read, but row-identifier columns belong up front.
    front = [c for c in ("country", "year") if c in df.columns]
    rest  = [c for c in df.columns if c not in front]
    return df[front + rest]


_PREFERENCE_VOTES = {
    "Germany": "germany_erststimme_candidates_by_wahlkreis.parquet",
    "Netherlands": "netherlands_preference_votes_by_stembureau.parquet",
}


def sage_preference_votes(country: str) -> pd.DataFrame:
    """Load the per-candidate vote sidecar for countries with open lists or
    candidate-level reporting (Germany Erststimme, Netherlands Tweede Kamer).

    Returns a pandas DataFrame; raises KeyError if no sidecar exists for
    ``country``.
    """
    if country not in _PREFERENCE_VOTES:
        raise KeyError(
            f"no preference-vote sidecar for {country!r}; "
            f"available: {sorted(_PREFERENCE_VOTES)}"
        )
    fname = _PREFERENCE_VOTES[country]
    src = get_source().rstrip("/")
    if src.endswith("/parquet"):
        src = src[: -len("/parquet")]
    if src.startswith("gs://"):
        from pyarrow import fs as pafs
        gcs = pafs.GcsFileSystem(anonymous=True)
        path = src[len("gs://"):] + "/preference_votes/" + fname
        return pq.read_table(path, filesystem=gcs).to_pandas()
    return pq.read_table(src + "/preference_votes/" + fname).to_pandas()


def sage_polygons(country: str, years: Optional[Iterable[int]] = None):
    """Load the polygon set for one country as a GeoDataFrame.

    SAGE ships a parallel ``polygons/`` tree (one geoparquet per country)
    alongside the main parquet release; the polygons carry only the
    ``NAME``-key + ``year`` + ``geometry`` columns and are deduplicated to
    one row per unique polygon. Use this when you need boundaries for
    choropleth mapping; the main :func:`sage_load` only returns lat/long.

    Requires :mod:`geopandas` (install with ``pip install sage-elections[geo]``).
    """
    try:
        import geopandas as gpd
    except ImportError:
        raise ImportError(
            "sage_polygons() requires geopandas; install with "
            "'pip install sage-elections[geo]'"
        )
    src = get_source().rstrip("/")
    # strip a trailing /parquet if the user pointed us at the parquet root
    if src.endswith("/parquet"):
        src = src[: -len("/parquet")]

    # Build the filesystem + base path the parquet readers understand.
    if src.startswith("gs://"):
        from pyarrow import fs as pafs
        gcs = pafs.GcsFileSystem(anonymous=True)
        bucket_path = src[len("gs://"):] + "/polygons"  # e.g. "sage-archive/polygons"
        import time
        index_url   = f"https://storage.googleapis.com/{bucket_path}/_index.csv?ts={int(time.time())}"
        def _full(rel: str) -> tuple:
            return (gcs, f"{bucket_path}/{rel}")
    else:
        bucket_path = src + "/polygons"
        index_url   = f"{bucket_path}/_index.csv"
        def _full(rel: str) -> tuple:
            return (None, f"{bucket_path}/{rel}")

    try:
        idx = pd.read_csv(index_url)
    except Exception:
        idx = None

    def _read(rel):
        fs_obj, path = _full(rel)
        if fs_obj is None:
            return gpd.read_parquet(path)
        return gpd.read_parquet(path, filesystem=fs_obj)

    if idx is not None:
        rows = idx[idx["country"] == country]
        if rows.empty:
            return None
        if years is not None:
            target = {int(y) for y in years}
            # NA-year rows are single-file layouts that already cover all
            # years; year-sharded rows have an integer year. Keep NA rows
            # as-is (we'll filter on the geometry side after read), and
            # for non-NA rows keep only those whose year is in target.
            yr = rows["year"]
            mask_na = yr.isna()
            mask_match = yr.notna() & yr.fillna(0).astype(int).isin(target)
            rows = rows[mask_na | mask_match]
        parts = [_read(p) for p in rows["path"]]
        out = parts[0] if len(parts) == 1 else gpd.GeoDataFrame(
            pd.concat(parts, ignore_index=True),
            crs=parts[0].crs if parts else None,
        )
        # Single-file layouts keep all years inside one file; apply the
        # year filter on the geometry rows themselves here.
        if years is not None and "year" in out.columns:
            out = out[out["year"].astype(int).isin([int(y) for y in years])]
        return out

    # Index unavailable: fall back to single-file path
    gdf = _read(f"{country}.parquet")
    if years is not None and "year" in gdf.columns:
        gdf = gdf[gdf["year"].astype(int).isin([int(y) for y in years])]
    return gdf
