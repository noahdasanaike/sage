#' Small-Area Global Elections (SAGE) Data Retrieval
#'
#' These helpers fetch partitioned Parquet from the SAGE public release
#' (default: a Google Cloud Storage bucket; override with `sage_set_source()`
#' or the SAGE_SOURCE environment variable) and let users pull (country, years,
#' columns) slices without reading the giant per-country RDS files.
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
#   3. fall back to the local J:/Output_c_parquet path used during development
.sage_default_source <- function() {
  s <- Sys.getenv("SAGE_SOURCE", unset = NA_character_)
  if (!is.na(s) && nzchar(s)) return(s)
  "gs://sage-archive/parquet"  # also reachable as https://storage.googleapis.com/sage-archive/parquet
}

.sage_state <- new.env(parent = emptyenv())
.sage_state$source <- NULL

#' Set the source URL/path for the SAGE archive.
#'
#' @param source A local path or remote URI (e.g., \code{"s3://bucket/path"},
#'   \code{"gs://bucket/path"}, \code{"https://example.com/sage_parquet"}).
#' @export
sage_set_source <- function(source) {
  stopifnot(is.character(source), length(source) == 1, nzchar(source))
  .sage_state$source <- source
  invisible(source)
}

.sage_source <- function() {
  if (!is.null(.sage_state$source)) return(.sage_state$source)
  .sage_default_source()
}

.open_dataset <- function() {
  src <- .sage_source()
  partitioning <- arrow::hive_partition(country = arrow::utf8(),
                                        year    = arrow::int32())
  # Anonymous gs:// reads need an explicit GcsFileSystem with anonymous=TRUE;
  # arrow's URI-only path tries to authenticate and fails on a public bucket
  # if the user has no GCP creds. Detect gs:// and route through the explicit
  # filesystem.
  if (grepl("^gs://", src)) {
    rest <- sub("^gs://", "", src)
    bucket <- sub("/.*$", "", rest)
    path   <- sub(paste0("^", bucket, "/?"), "", rest)
    fs <- arrow::GcsFileSystem$create(anonymous = TRUE)
    target <- if (nzchar(path)) paste0(bucket, "/", path) else bucket
    return(arrow::open_dataset(target, filesystem = fs,
                               partitioning = partitioning,
                               format = "parquet"))
  }
  arrow::open_dataset(src, partitioning = partitioning, format = "parquet")
}

# Read the lightweight `_index.csv` that ships alongside the parquet so we
# can answer sage_countries() / sage_years() without enumerating every
# partition file over the network. Returns NULL on failure (caller falls
# back to walking the dataset).
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

#' List countries available in the current source.
#' @export
sage_countries <- function() {
  idx <- .read_index()
  if (!is.null(idx) && "country" %in% names(idx)) {
    return(sort(unique(as.character(idx$country))))
  }
  ds <- .open_dataset()
  sort(unique(as.data.frame(dplyr::collect(dplyr::distinct(ds, .data$country)))$country))
}

#' List election years available for a country.
#' @param country Country name (e.g., \code{"Germany"}).
#' @export
sage_years <- function(country) {
  idx <- .read_index()
  if (!is.null(idx) && all(c("country","year") %in% names(idx))) {
    return(sort(unique(as.integer(idx$year[idx$country == country]))))
  }
  ds <- .open_dataset()
  out <- dplyr::collect(dplyr::distinct(dplyr::filter(ds, .data$country == !!country),
                                        .data$year))
  sort(out$year)
}

#' List the columns available in the dataset.
#' @export
sage_columns <- function() {
  ds <- .open_dataset()
  ds$schema$names
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
#' @return A tibble.
#' @examples
#' \dontrun{
#' library(sage)
#' sage_set_source("https://storage.googleapis.com/sage-archive/parquet")
#' de_2021 <- sage_load("Germany", years = 2021, columns = c("party","votes","NAME3"))
#' all_de_high <- sage_load("Germany", min_match_confidence = "high")
#' }
#' @export
sage_load <- function(country,
                      years = NULL,
                      columns = NULL,
                      election_type = NULL,
                      min_match_confidence = NULL) {
  stopifnot(is.character(country), length(country) == 1)

  ds <- .open_dataset()
  q  <- dplyr::filter(ds, .data$country == !!country)
  if (!is.null(years)) {
    years <- as.integer(years)
    q <- dplyr::filter(q, .data$year %in% !!years)
  }
  if (!is.null(election_type)) {
    q <- dplyr::filter(q, .data$election_type %in% !!election_type)
  }
  if (!is.null(min_match_confidence)) {
    levels_keep <- switch(
      min_match_confidence,
      high   = c("high"),
      medium = c("high","medium"),
      low    = c("high","medium","low"),
      stop("min_match_confidence must be one of 'high','medium','low'.")
    )
    q <- dplyr::filter(q, .data$match_confidence %in% !!levels_keep)
  }
  if (!is.null(columns)) {
    columns <- unique(c(columns, "country", "year"))  # preserve partition cols
    q <- dplyr::select(q, dplyr::all_of(columns))
  }
  tibble::as_tibble(dplyr::collect(q))
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
    Netherlands = "netherlands_preference_votes_by_stembureau_2021.parquet"
  )
  if (!country %in% names(files)) {
    stop("no preference-vote sidecar for ", country,
         "; available: ", paste(names(files), collapse = ", "))
  }
  src <- .sage_source()
  base <- if (grepl("^gs://", src)) {
    paste0("https://storage.googleapis.com/",
           sub("^gs://", "", sub("/parquet/?$", "", src)),
           "/preference_votes")
  } else if (grepl("^https?://", src)) {
    paste0(sub("/parquet/?$", "", sub("/$", "", src)), "/preference_votes")
  } else {
    file.path(sub("/parquet/?$", "", src), "..", "Output_c", "preference_votes")
  }
  url <- paste0(base, "/", files[[country]])
  tibble::as_tibble(arrow::read_parquet(url))
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
  if (!requireNamespace("sf",       quietly = TRUE)) stop("sage_polygons() requires the 'sf' package")
  if (!requireNamespace("sfarrow",  quietly = TRUE)) stop("sage_polygons() requires the 'sfarrow' package")
  src <- .sage_source()
  poly_root <- if (grepl("^gs://", src)) {
    paste0("https://storage.googleapis.com/",
           sub("^gs://", "", sub("/parquet/?$", "", src)),
           "/polygons")
  } else if (grepl("^https?://", src)) {
    paste0(sub("/parquet/?$", "", sub("/$", "", src)), "/polygons")
  } else {
    sub("/parquet/?$", "", src) %>% file.path("../Output_c_polygons")
  }
  # Local dev fallback: J:/Output_c_polygons
  # Two layouts: most countries are a single <Country>.parquet; the two that
  # blew through Arrow's 2 GB single-array limit (Japan, USA) are sharded into
  # <Country>/year=<Y>.parquet files. Use the polygon _index.csv to figure
  # out which.
  idx_url <- paste0(poly_root, "/_index.csv")
  poly_idx <- tryCatch(read.csv(idx_url, stringsAsFactors = FALSE),
                       error = function(e) NULL)
  if (!is.null(poly_idx)) {
    rows <- poly_idx[poly_idx$country == country, , drop = FALSE]
    if (nrow(rows) == 0) {
      return(invisible(NULL))
    }
    if (!is.null(years)) {
      yr_int <- as.integer(rows$year)
      keep <- is.na(yr_int) | yr_int %in% as.integer(years)
      rows <- rows[keep, , drop = FALSE]
    }
    enc <- function(p) paste(vapply(strsplit(p, "/", fixed = TRUE)[[1]],
                                    utils::URLencode, character(1),
                                    reserved = TRUE), collapse = "/")
    files <- vapply(rows$path, function(p) paste0(poly_root, "/", enc(p)),
                    character(1))
    parts <- lapply(files, sfarrow::st_read_parquet)
    if (length(parts) == 1) return(parts[[1]])
    return(do.call(rbind, parts))
  }
  # Index unavailable: fall back to single-file path (URL-encode the country
  # name in case it contains spaces).
  d <- sfarrow::st_read_parquet(
    paste0(poly_root, "/", utils::URLencode(country, reserved = TRUE), ".parquet"))
  if (!is.null(years) && "year" %in% names(d)) {
    d <- d[as.integer(d$year) %in% as.integer(years), , drop = FALSE]
  }
  d
}
