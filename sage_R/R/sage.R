#' Small-Area Global Elections (SAGE) Data Retrieval
#'
#' These helpers fetch partitioned Parquet from the SAGE public release
#' (default: a Google Cloud Storage bucket; override with `sage_set_source()`
#' or the SAGE_SOURCE environment variable) and let users pull (country, years,
#' columns) slices without reading the giant per-country RDS files.
#'
#' Remote reads go over plain HTTPS (one partition file at a time, guided by the
#' `_index.csv` manifest), so the package works with any build of \pkg{arrow} --
#' it does not require Arrow's S3/GCS cloud filesystem to be compiled in.
#'
#' When the source is the public bucket and \pkg{arrow} does have GCS support
#' compiled in, \code{sage_columns()} reads Parquet schemas through Arrow's
#' random-access reader instead of downloading whole partitions. That is an
#' optimization only: it falls back to the HTTPS download path whenever the
#' cloud filesystem or an individual read is unavailable.
#'
#' @section Source layout:
#' The release is a hive-partitioned Parquet dataset:
#' \preformatted{
#' <source>/
#'   country=Afghanistan/year=2014/part-0.parquet
#'   country=Afghanistan/year=2019/part-0.parquet
#'   country=Albania/year=2009/part-0.parquet
#'   ...
#'   _index.csv
#' }
#' so a (country, year) slice is a single partition read.
#'
#' @section Offline excerpt:
#' Every example in this package runs against a small excerpt of the archive
#' (Iceland and Samoa) shipped under \code{extdata/mini_archive}, so no network
#' access is required to try the interface:
#' \preformatted{
#' sage_set_source(system.file("extdata", "mini_archive", package = "sage"))
#' }
#' Point \code{sage_set_source()} back at \code{"gs://sage-archive/parquet"} to
#' use the full release.
#'
#' @name sage
#' @importFrom rlang .data
NULL

# Default source. Resolution order:
#   1. value set by sage_set_source()
#   2. SAGE_SOURCE environment variable
#   3. the public GCS bucket (read over HTTPS)
.sage_default_source <- function() {
  s <- Sys.getenv("SAGE_SOURCE", unset = NA_character_)
  if (!is.na(s) && nzchar(s)) return(s)
  "gs://sage-archive/parquet"  # also reachable as https://storage.googleapis.com/sage-archive/parquet
}

.sage_state <- new.env(parent = emptyenv())
.sage_state$source  <- NULL
.sage_state$columns <- NULL  # cached union column list (remote sources)

#' Set the source URL or path for the SAGE archive
#'
#' Sets the archive every other function in the package reads from. The setting
#' is global to the session and persists until it is changed again; unset, the
#' package falls back to the \code{SAGE_SOURCE} environment variable and then to
#' the public bucket.
#'
#' @param source A local path or remote URI (e.g., \code{"gs://bucket/path"},
#'   \code{"https://example.com/sage_parquet"}, or a local directory). A
#'   trailing slash on a remote URI is ignored.
#' @return The source, invisibly.
#' @seealso [sage_load()] to read a slice from the source that is set here.
#' @examples
#' # Point the package at the offline excerpt that ships with it.
#' sage_set_source(system.file("extdata", "mini_archive", package = "sage"))
#' sage_countries()
#'
#' \dontrun{
#' # The full public release (requires network access).
#' sage_set_source("gs://sage-archive/parquet")
#' }
#' @export
sage_set_source <- function(source) {
  stopifnot(is.character(source), length(source) == 1, nzchar(source))
  .sage_state$source  <- source
  .sage_state$columns <- NULL
  invisible(source)
}

.sage_source <- function() {
  s <- if (!is.null(.sage_state$source)) .sage_state$source else .sage_default_source()
  # Drop any trailing slash on a remote source: it would otherwise produce keys
  # like '<prefix>//_index.csv', which object storage treats as a distinct (and
  # absent) object. Local paths are left alone and go through file.path().
  if (grepl("^gs://|^https?://", s)) sub("/+$", "", s) else s
}

.is_remote <- function(src = .sage_source()) grepl("^gs://|^https?://", src)

# HTTPS base for the parquet release, whatever scheme the source uses.
.https_base <- function() {
  src <- .sage_source()
  if (grepl("^gs://", src)) paste0("https://storage.googleapis.com/", sub("^gs://", "", src))
  else sub("/$", "", src)
}

# HTTPS root of the whole archive (one level up from the parquet/ tree), used by
# the polygon and preference-vote sidecars.
.archive_root_https <- function() {
  src <- .sage_source()
  if (grepl("^gs://", src))
    paste0("https://storage.googleapis.com/", sub("^gs://", "", sub("/parquet/?$", "", src)))
  else sub("/parquet/?$", "", sub("/$", "", src))
}

# _index.csv records the hive paths exactly as they appear in the object keys,
# where Arrow has already percent-encoded characters such as spaces
# (country=Bosnia%20and%20Herzegovina/...). To request that key over HTTP the
# literal '%' must itself be escaped to %25.
.path_to_url <- function(relpath, base = .https_base()) {
  paste0(base, "/", gsub("%", "%25", relpath))
}

# Read one parquet to a data.frame. Remote files are downloaded with base R and
# read locally, so no Arrow cloud filesystem is needed.
.read_parquet_any <- function(path_or_url) {
  if (.is_remote(path_or_url)) {
    tmp <- tempfile(fileext = ".parquet")
    on.exit(unlink(tmp), add = TRUE)
    utils::download.file(path_or_url, tmp, mode = "wb", quiet = TRUE)
    return(as.data.frame(arrow::read_parquet(tmp)))
  }
  as.data.frame(arrow::read_parquet(path_or_url))
}

# Read the lightweight `_index.csv` that ships alongside the parquet so we can
# answer sage_countries() / sage_years() and locate partitions without
# enumerating the bucket. Returns NULL on failure.
.read_index <- function() {
  src <- .sage_source()
  url <- if (grepl("^gs://", src)) {
    paste0("https://storage.googleapis.com/", sub("^gs://", "", src), "/_index.csv")
  } else if (grepl("^https?://", src)) {
    paste0(sub("/$", "", src), "/_index.csv")
  } else {
    file.path(src, "_index.csv")
  }
  tryCatch(suppressWarnings(utils::read.csv(url, stringsAsFactors = FALSE)),
           error = function(e) NULL)
}

# A remote source that cannot be reached is the common failure here, so say so
# rather than leaving the user with a bare parse error from read.csv() or a
# filesystem error from Arrow.
.stop_unreadable <- function() {
  src <- .sage_source()
  stop("could not read the SAGE archive at '", src, "'.",
       if (.is_remote(src))
         " The source may be temporarily unreachable; check your network connection."
       else
         " Check that the directory exists and contains _index.csv.",
       " Use sage_set_source() to read from somewhere else.",
       call. = FALSE)
}

# Local-only lazy dataset (used when the source is a local directory; needs no
# cloud filesystem).
#
# Only a fallback for a local copy with no _index.csv: Arrow takes the schema
# from the first fragment alone, and partitions here carry different column
# sets (Samoa has `candidate`, Iceland does not), so columns absent from the
# first fragment are lost. Arrow's unify_schemas = TRUE is not an option --
# geometry_level is int32 in some partitions and double in others, which fails
# to merge. Whenever the index is available, .partition_path() is used instead
# and each partition is read on its own terms.
.open_local <- function() {
  ds <- tryCatch(
    arrow::open_dataset(
      .sage_source(),
      partitioning = arrow::hive_partition(country = arrow::utf8(), year = arrow::int32()),
      format = "parquet"),
    error = function(e) NULL)
  if (is.null(ds)) .stop_unreadable()
  ds
}

# Where one path from _index.csv actually lives, for either kind of source.
# Only remote keys need the percent re-escaping; on disk the key is the
# literal directory name.
.partition_path <- function(relpath) {
  if (.is_remote()) .path_to_url(relpath) else file.path(.sage_source(), relpath)
}

# Column names of a single partition, without reading its data. Remote sources
# use Arrow's random-access reader when the build has GCS support (gcs is the
# filesystem, gcs_root the bucket prefix); otherwise the partition is
# downloaded whole, which is what every build could always do.
.partition_columns <- function(relpath, gcs = NULL, gcs_root = NULL) {
  if (!.is_remote()) {
    return(names(arrow::open_dataset(.partition_path(relpath), format = "parquet")))
  }
  if (!is.null(gcs)) {
    cols <- tryCatch(
      arrow::ParquetFileReader$create(
        gcs$OpenInputFile(paste0(gcs_root, "/", relpath)))$GetSchema()$names,
      error = function(e) NULL)
    if (!is.null(cols)) return(cols)
  }
  tmp <- tempfile(fileext = ".parquet")
  on.exit(unlink(tmp), add = TRUE)
  utils::download.file(.partition_path(relpath), tmp, mode = "wb", quiet = TRUE)
  names(arrow::open_dataset(tmp, format = "parquet"))
}

# The GCS filesystem, or NULL when the source is not the public bucket or the
# installed arrow has no GCS support compiled in.
.gcs_handle <- function() {
  src  <- .sage_source()
  root <- if (grepl("^gs://", src)) {
    sub("^gs://", "", src)
  } else if (grepl("^https?://storage\\.googleapis\\.com/", src)) {
    sub("^https?://storage\\.googleapis\\.com/", "", src)
  } else {
    return(NULL)
  }
  fs <- tryCatch(arrow::GcsFileSystem$create(anonymous = TRUE), error = function(e) NULL)
  if (is.null(fs)) NULL else list(fs = fs, root = root)
}

#' List countries available in the current source
#'
#' Reads the \code{_index.csv} manifest that ships with the archive, so this
#' costs one small request rather than a scan of the bucket.
#'
#' @return A character vector of country names, sorted.
#' @seealso [sage_years()], [sage_load()]
#' @examples
#' sage_set_source(system.file("extdata", "mini_archive", package = "sage"))
#' sage_countries()
#' @export
sage_countries <- function() {
  idx <- .read_index()
  if (!is.null(idx) && "country" %in% names(idx)) {
    return(sort(unique(as.character(idx$country))))
  }
  if (!.is_remote()) {
    ds <- .open_local()
    return(sort(unique(as.data.frame(dplyr::collect(dplyr::distinct(ds, .data$country)))$country)))
  }
  .stop_unreadable()
}

#' List election years available for a country
#'
#' @param country Country name (e.g., \code{"Germany"}), as returned by
#'   [sage_countries()].
#' @return An integer vector of years, sorted. A country with no partitions in
#'   the source gives a zero-length vector.
#' @seealso [sage_countries()], [sage_load()]
#' @examples
#' sage_set_source(system.file("extdata", "mini_archive", package = "sage"))
#' sage_years("Iceland")
#' @export
sage_years <- function(country) {
  idx <- .read_index()
  if (!is.null(idx) && all(c("country", "year") %in% names(idx))) {
    return(sort(unique(as.integer(idx$year[idx$country == country]))))
  }
  if (!.is_remote()) {
    ds <- .open_local()
    out <- dplyr::collect(dplyr::distinct(dplyr::filter(ds, .data$country == !!country), .data$year))
    return(sort(out$year))
  }
  .stop_unreadable()
}

#' List the columns available in the dataset
#'
#' Not every column is populated for every country; this returns the union of
#' columns over the largest partition of each of several countries, which is
#' what surfaces the optional deep-hierarchy columns (\code{NAME4},
#' \code{NAME5}, ...). The answer is cached for the session, and is discarded
#' when [sage_set_source()] changes the source.
#'
#' @return A character vector of column names, beginning with \code{"country"}
#'   and \code{"year"}.
#' @seealso [sage_load()], whose \code{columns} argument takes these names.
#' @examples
#' sage_set_source(system.file("extdata", "mini_archive", package = "sage"))
#' sage_columns()
#' @export
sage_columns <- function() {
  if (!is.null(.sage_state$columns)) return(.sage_state$columns)
  idx <- .read_index()
  if (is.null(idx) || !"path" %in% names(idx)) {
    # A local copy with no manifest: Arrow's dataset schema is all there is.
    if (!.is_remote()) return(.open_local()$schema$names)
    .stop_unreadable()
  }
  # Union the schema over the largest partition of several distinct countries;
  # deep administrative hierarchies surface the optional NAME4/NAME5/... columns.
  o <- idx[order(-idx$bytes), , drop = FALSE]
  o <- o[!duplicated(o$country), , drop = FALSE]
  o <- utils::head(o, 6)
  gcs  <- .gcs_handle()
  cols <- character(0)
  for (i in seq_len(nrow(o))) {
    cols <- union(cols, .partition_columns(o$path[i], gcs$fs, gcs$root))
  }
  out <- union(c("country", "year"), cols)
  .sage_state$columns <- out
  out
}

#' Load a (country, years, columns) slice of SAGE
#'
#' Reads only the partitions the request needs, one file per (country, year),
#' and returns them as a single tibble.
#'
#' @param country Single country name; required.
#' @param years Optional integer vector of years (default: all available).
#' @param columns Optional character vector of column names (default: all).
#' @param election_type Optional character filter on \code{election_type}
#'   (e.g., \code{"Presidential"}).
#' @param min_match_confidence If non-NULL, restricts to rows whose
#'   \code{match_confidence} is at least this strict (\code{"high"} keeps only
#'   high; \code{"medium"} keeps high+medium; etc.).
#' @param drop_all_na Drop columns that are entirely NA for the slice. The
#'   union schema carries every column any partition has, so a country slice
#'   would otherwise show columns that never apply to it.
#' @return A tibble, with \code{country} and \code{year} as the first two
#'   columns.
#' @seealso [sage_columns()] for the available columns, [sage_polygons()] for
#'   boundaries.
#' @examples
#' sage_set_source(system.file("extdata", "mini_archive", package = "sage"))
#' is_2020 <- sage_load("Iceland", years = 2020)
#' dim(is_2020)
#' names(is_2020)
#'
#' # Restrict to a few columns; country and year are always kept.
#' sage_load("Iceland", years = 2020, columns = c("party", "votes"))
#'
#' \dontrun{
#' # Against the full release (requires network access).
#' sage_set_source("gs://sage-archive/parquet")
#' de_2021 <- sage_load("Germany", years = 2021, columns = c("party", "votes", "NAME3"))
#' all_de_high <- sage_load("Germany", min_match_confidence = "high")
#' }
#' @export
sage_load <- function(country,
                      years = NULL,
                      columns = NULL,
                      election_type = NULL,
                      min_match_confidence = NULL,
                      drop_all_na = TRUE) {
  stopifnot(is.character(country), length(country) == 1)

  conf_levels <- function(x) switch(
    x,
    high   = c("high"),
    medium = c("high", "medium"),
    low    = c("high", "medium", "low"),
    stop("min_match_confidence must be one of 'high','medium','low'."))

  # The manifest drives the read for both kinds of source. Reading partition
  # files one at a time is what lets a country keep the columns only it has:
  # Arrow's dataset schema comes from a single fragment, so the local branch
  # below (no manifest) can only see that fragment's columns.
  idx <- .read_index()
  if (!is.null(idx) && all(c("country", "year", "path") %in% names(idx))) {
    rows <- idx[idx$country == country, , drop = FALSE]
    if (!is.null(years))
      rows <- rows[as.integer(rows$year) %in% as.integer(years), , drop = FALSE]
    if (nrow(rows) == 0)
      stop("no data for country = '", country, "'",
           if (!is.null(years)) paste0(" in year(s) ", paste(years, collapse = ", ")) else "", ".")
    parts <- lapply(seq_len(nrow(rows)), function(i) {
      d <- .read_parquet_any(.partition_path(rows$path[i]))
      # Hive partition columns live in the path, not the file; restore them.
      d$country <- rows$country[i]
      d$year    <- as.integer(rows$year[i])
      d
    })
    out <- tibble::as_tibble(dplyr::bind_rows(parts))
    if (!is.null(election_type) && "election_type" %in% names(out))
      out <- out[out$election_type %in% election_type, , drop = FALSE]
    if (!is.null(min_match_confidence) && "match_confidence" %in% names(out))
      out <- out[out$match_confidence %in% conf_levels(min_match_confidence), , drop = FALSE]
    if (!is.null(columns)) {
      keep <- intersect(unique(c("country", "year", columns)), names(out))
      out  <- out[, keep, drop = FALSE]
    }
  } else if (.is_remote()) {
    .stop_unreadable()
  } else {
    ds <- .open_local()
    q  <- dplyr::filter(ds, .data$country == !!country)
    if (!is.null(years)) {
      years <- as.integer(years)
      q <- dplyr::filter(q, .data$year %in% !!years)
    }
    if (!is.null(election_type))
      q <- dplyr::filter(q, .data$election_type %in% !!election_type)
    if (!is.null(min_match_confidence))
      q <- dplyr::filter(q, .data$match_confidence %in% !!conf_levels(min_match_confidence))
    if (!is.null(columns)) {
      # any_of, not all_of: a name the source does not carry is dropped rather
      # than an error, matching what the remote path does with intersect().
      columns <- unique(c("country", "year", columns))
      q <- dplyr::select(q, dplyr::any_of(columns))
    }
    out <- tibble::as_tibble(dplyr::collect(q))
  }

  # Drop columns that are entirely NA for this country slice. Without this,
  # the union schema surfaces every column that any partition carries (e.g.,
  # NAME4 from Brazil on an Iceland slice). Set drop_all_na = FALSE to keep them.
  if (drop_all_na && nrow(out) > 0) {
    keep <- vapply(out, function(x) !all(is.na(x)), logical(1))
    out <- out[, keep, drop = FALSE]
  }

  # country and year up front, next to the rest of the row identifiers.
  front <- intersect(c("country", "year"), colnames(out))
  rest  <- setdiff(colnames(out), front)
  out[, c(front, rest), drop = FALSE]
}

#' Load the per-candidate vote sidecar
#'
#' Some countries report votes for individual candidates alongside the party
#' totals in the main release. This reads that sidecar. It is available for
#' Germany (Erststimme by Wahlkreis) and the Netherlands (preference votes by
#' stembureau); any other country is an error.
#'
#' @param country Country name; one of \code{"Germany"} or
#'   \code{"Netherlands"}.
#' @return A tibble of candidate-level votes.
#' @seealso [sage_load()] for the main party-level release.
#' @examples
#' \dontrun{
#' # Requires network access; the sidecar is not part of the offline excerpt.
#' sage_set_source("gs://sage-archive/parquet")
#' de_cand <- sage_preference_votes("Germany")
#' }
#' @export
sage_preference_votes <- function(country) {
  stopifnot(is.character(country), length(country) == 1)
  files <- list(
    Germany     = "germany_erststimme_candidates_by_wahlkreis.parquet",
    Netherlands = "netherlands_preference_votes_by_stembureau.parquet"
  )
  if (!country %in% names(files)) {
    stop("no preference-vote sidecar for ", country,
         "; available: ", paste(names(files), collapse = ", "))
  }
  base <- if (.is_remote()) paste0(.archive_root_https(), "/preference_votes")
          else file.path(sub("/parquet/?$", "", .sage_source()), "..", "Output_c", "preference_votes")
  tibble::as_tibble(.read_parquet_any(paste0(base, "/", files[[country]])))
}

#' Load the polygon set for one country
#'
#' SAGE ships a parallel \code{polygons/} tree (one geoparquet per country)
#' alongside the main parquet release; the polygons carry only the
#' \code{NAME}-key + \code{year} + \code{geometry} columns and are
#' deduplicated to one row per unique polygon. Use this helper when you need
#' boundaries for choropleth mapping; the main \code{sage_load()} only
#' returns lat/long.
#'
#' Requires the \pkg{sf} and \pkg{sfarrow} packages.
#' @param country Country name.
#' @param years Optional integer vector of years.
#' @return An \code{sf} data frame, or \code{NULL} invisibly if the source has
#'   no polygons for the country.
#' @seealso [sage_load()] for the vote data these boundaries join to.
#' @examples
#' \dontrun{
#' # Requires network access, plus the sf and sfarrow packages; polygons are
#' # not part of the offline excerpt.
#' sage_set_source("gs://sage-archive/parquet")
#' is_poly <- sage_polygons("Iceland", years = 2021)
#' }
#' @export
sage_polygons <- function(country, years = NULL) {
  if (!requireNamespace("sf",      quietly = TRUE)) stop("sage_polygons() requires the 'sf' package")
  if (!requireNamespace("sfarrow", quietly = TRUE)) stop("sage_polygons() requires the 'sfarrow' package")
  poly_root <- if (.is_remote()) paste0(.archive_root_https(), "/polygons")
               else file.path(sub("/parquet/?$", "", .sage_source()), "..", "Output_c_polygons")

  # Read one geoparquet to an sf object, downloading first on remote sources so
  # no Arrow cloud filesystem is needed. Polygon object keys carry literal
  # spaces, so each path segment is percent-encoded once.
  enc <- function(p) paste(vapply(strsplit(p, "/", fixed = TRUE)[[1]],
                                  utils::URLencode, character(1), reserved = TRUE), collapse = "/")
  read_poly <- function(relpath) {
    if (.is_remote()) {
      tmp <- tempfile(fileext = ".parquet")
      on.exit(unlink(tmp), add = TRUE)
      utils::download.file(paste0(poly_root, "/", enc(relpath)), tmp, mode = "wb", quiet = TRUE)
      return(sfarrow::st_read_parquet(tmp))
    }
    sfarrow::st_read_parquet(file.path(poly_root, relpath))
  }

  # Two layouts: most countries are a single <Country>.parquet; the two that
  # blew through Arrow's 2 GB single-array limit (Japan, USA) are sharded into
  # <Country>/year=<Y>.parquet. The polygon _index.csv records which.
  idx_url  <- if (.is_remote()) paste0(poly_root, "/_index.csv") else file.path(poly_root, "_index.csv")
  poly_idx <- tryCatch(suppressWarnings(utils::read.csv(idx_url, stringsAsFactors = FALSE)),
                       error = function(e) NULL)
  if (!is.null(poly_idx)) {
    rows <- poly_idx[poly_idx$country == country, , drop = FALSE]
    if (nrow(rows) == 0) return(invisible(NULL))
    if (!is.null(years)) {
      yr_int <- as.integer(rows$year)
      rows <- rows[is.na(yr_int) | yr_int %in% as.integer(years), , drop = FALSE]
    }
    parts <- lapply(rows$path, read_poly)
    if (length(parts) == 1) return(parts[[1]])
    return(do.call(rbind, parts))
  }
  # Index unavailable: fall back to the single-file <Country>.parquet path.
  d <- read_poly(paste0(country, ".parquet"))
  if (!is.null(years) && "year" %in% names(d)) {
    d <- d[as.integer(d$year) %in% as.integer(years), , drop = FALSE]
  }
  d
}
