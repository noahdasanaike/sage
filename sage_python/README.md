# sage (Python package)

`sage` provides convenience helpers for the Small-Area Global Elections (SAGE)
archive. It lets you pull a (country, years, columns) slice without ever
downloading the full per-country files. Under the hood it queries the
hive-partitioned Parquet release through Apache Arrow.

## Install (development)

```bash
pip install -e .
# or, when published:
# pip install sage-elections
```

## Usage

```python
import sage

# Point to the public release (or any Arrow-readable URI)
sage.set_source("gs://sage-archive/parquet")
# or, on the original machine:
# sage.set_source("J:/Output_c_parquet")

# What's available?
sage.sage_countries()                   # 131 country names
sage.sage_years("Germany")              # [1998, 2002, 2005, 2009, 2013, 2017, 2021]
sage.sage_columns()                     # all release columns

# Pull a slice into pandas
de_2021 = sage.sage_load(
    "Germany",
    years=[2021],
    columns=["party", "votes", "NAME3", "NAME5"],
)

# All Italian presidential rows where the Party Facts match is high or medium:
it_pres = sage.sage_load(
    "Italy",
    election_type="Presidential",
    min_match_confidence="medium",
)
```

`sage_load` returns a `pandas.DataFrame`. The Parquet partitioning is on
`country` + `year`, so the most common subsetting (one country, one or a
few years) is a single partition read and returns in seconds.

For SQL users, the same dataset can be queried via DuckDB without going
through this package:

```python
import duckdb
con = duckdb.connect()
con.sql("INSTALL httpfs; LOAD httpfs;")
con.sql("""
  SELECT party, sum(votes) AS total
  FROM read_parquet('gs://sage-archive/parquet/country=Germany/**.parquet',
                    hive_partitioning = TRUE)
  WHERE year = 2021
  GROUP BY party
  ORDER BY total DESC
""").df()
```
