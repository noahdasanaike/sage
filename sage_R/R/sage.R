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
#' @name sage
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

#' Set the source URL/path for the SAGE archive.
#'
#' @param source A local path or remote URI (e.g., \code{"gs://bucket/path"},
#'   \code{"https://example.com/sage_parquet"}, or a local directory).
#' @export
sage_set_source <- function(source) {
  stopifnot(is.character(source), length(source) == 1, nzchar(source))
  .sage_state$source  <- source
  .sage_state$columns <- NULL
  invisible(source)
}

.sage_source <- function() {
  if (!is.null(.sage_state$source)) return(.sage_state$source)
  .sage_default_source()
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
  tryCatch(read.csv(url, stringsAsFactors = FALSE), error = function(e) NULL)
}

# Local-only lazy dataset (used when the source is a local directory; needs no
# cloud filesystem).
.open_local <- function() {
  arrow::open_dataset(
    .sage_source(),
    partitioning = arrow::hive_partition(country = arrow::utf8(), year = arrow::int32()),
    format = "parquet")
}

#' List countries available in the current source.
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
  stop("could not read the SAGE index (_index.csv) from the source.")
}

#' List election years available for a country.
#' @param country Country name (e.g., \code{"Germany"}).
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
  stop("could not read the SAGE index (_index.csv) from the source.")
}

#' List the columns available in the dataset.
#'
#' Not every column is populated for every country; this returns the union of
#' columns across the dataset.
#' @export
sage_columns <- function() {
  if (!.is_remote()) return(.open_local()$schema$names)
  if (!is.null(.sage_state$columns)) return(.sage_state$columns)
  idx <- .read_index()
  if (is.null(idx) || !"path" %in% names(idx))
    stop("could not read the SAGE index (_index.csv) from the source.")
  # Union the schema over the largest partition of several distinct countries;
  # deep administrative hierarchies surface the optional NAME4/NAME5/... columns.
  o <- idx[order(-idx$bytes), , drop = FALSE]
  o <- o[!duplicated(o$country), , drop = FALSE]
  o <- utils::head(o, 6)
  cols <- character(0)
  for (i in seq_len(nrow(o))) {
    tmp <- tempfile(fileext = ".parquet")
    utils::download.file(.path_to_url(o$path[i]), tmp, mode = "wb", quiet = TRUE)
    cols <- union(cols, names(arrow::open_dataset(tmp, format = "parquet")))
    unlink(tmp)
  }
  out <- union(c("country", "year"), cols)
  .sage_state$columns <- out
  out
}

#' Load a (country, years, columns) slice of SAGE.
#'
#' @param country Single country name; required.
#' @param years Optional integer vector of years (default: all available).
#' @param columns Optional character vector of column names (default: all).
#' @param election_type Optional character filter on \code{election_type}
#'   (e.g., \code{"Presidential"}).
#' @param min_match_confidence If non-NULL, restricts to rows whose
#'   \code{match_confidence} is at least this strict (\code{"high"} keeps only
#'   high; \code{"medium"} keeps high+medium; etc.).
#' @param drop_all_na Drop columns that are entirely NA for the slice.
#' @return A tibble.
#' @examples
#' \dontrun{
#' library(sage)
#' de_2021 <- sage_load("Germany", years = 2021, columns = c("party","votes","NAME3"))
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

  if (.is_remote()) {
    idx <- .read_index()
    if (is.null(idx) || !all(c("country", "year", "path") %in% names(idx)))
      stop("could not read the SAGE index (_index.csv) from the source.")
    rows <- idx[idx$country == country, , drop = FALSE]
    if (!is.null(years))
      rows <- rows[as.integer(rows$year) %in% as.integer(years), , drop = FALSE]
    if (nrow(rows) == 0)
      stop("no data for country = '", country, "'",
           if (!is.null(years)) paste0(" in year(s) ", paste(years, collapse = ", ")) else "", ".")
    base  <- .https_base()
    parts <- lapply(seq_len(nrow(rows)), function(i) {
      d <- .read_parquet_any(.path_to_url(rows$path[i], base))
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
      columns <- unique(c(columns, "country", "year"))
      q <- dplyr::select(q, dplyr::all_of(columns))
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

#' Load the per-candidate vote sidecar for countries with open lists or
#' candidate-level reporting (Germany Erststimme; Netherlands Tweede Kamer).
#'
#' @param country Country name.
#' @return A tibble.
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

#' Load the polygon set for one country.
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
#' @return An \code{sf} data frame.
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
  poly_idx <- tryCatch(read.csv(idx_url, stringsAsFactors = FALSE), error = function(e) NULL)
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
