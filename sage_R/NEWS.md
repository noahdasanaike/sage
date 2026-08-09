# sage 0.2.0

* `sage_columns()` now reads Parquet schemas through Arrow's random-access GCS
  reader when the source is the public bucket and the installed `arrow` has GCS
  support compiled in, instead of downloading six whole partitions (about
  298 MB) to inspect their schemas. Roughly a 2-4x speedup on a cold cache. The
  full-download path remains as a fallback, so builds of `arrow` without a
  cloud filesystem behave exactly as before (thanks, @dshkol, #118).

* A trailing slash on a remote source (`"gs://sage-archive/parquet/"`) no
  longer produces a doubled separator and a missing-object error. Remote
  sources are normalized once, in `.sage_source()`.

* `http://storage.googleapis.com/...` sources take the same fast path as
  `https://` ones.

* The package now ships a small offline excerpt of the archive (Iceland and
  Samoa, 26 KB) under `extdata/mini_archive`, so every example runs without
  network access.

* Failure to read the archive index now reports which source was tried and
  whether the likely cause is an unreachable remote.

* Added documentation for all exported functions, a test suite, and a LICENSE
  file.

# sage 0.1.0

* First release: `sage_load()`, `sage_countries()`, `sage_years()`,
  `sage_columns()`, `sage_polygons()`, `sage_preference_votes()`, and
  `sage_set_source()`.
