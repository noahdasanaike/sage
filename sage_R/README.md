# sage (R package)

Convenience helpers for the Small-Area Global Elections (SAGE) archive.

`sage` lets you pull a (country, years, columns) slice without ever reading
the giant per-country RDS files. Under the hood it queries the partitioned
Parquet release through Apache Arrow.

## Install (development)

```r
# install.packages("remotes")
remotes::install_github("noahdasanaike/sage", subdir = "sage_R")
```

## Usage

```r
library(sage)

# Point to the public release (or any Arrow-readable URI)
sage_set_source("https://storage.googleapis.com/sage-archive/parquet")
# or, on the original machine:
# sage_set_source("J:/Output_c_parquet")

# What's available?
sage_countries()                  # 131 country names
sage_years("Germany")             # c(1998, 2002, 2005, 2009, 2013, 2017, 2021)
sage_columns()                    # all release columns

# Pull a slice
de_2021 <- sage_load(
  "Germany",
  years   = 2021,
  columns = c("party", "votes", "NAME3", "NAME5")
)

# All Italian presidential rows where the Party Facts match is high or medium:
it_pres <- sage_load(
  "Italy",
  election_type        = "Presidential",
  min_match_confidence = "medium"
)
```

`sage_load` returns a tibble. The Parquet partitioning is on
`country` + `year`, so the most common subsetting (one country, one or a
few years) is a single partition read and returns in seconds.
