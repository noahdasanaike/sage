# The offline excerpt shipped in inst/extdata. Every test that does not
# explicitly want the network runs against this.
mini <- function() system.file("extdata", "mini_archive", package = "sage")

# sage_set_source() is global to the session, so restore whatever was set
# before each test that changes it.
with_source <- function(src, code) {
  # Bind the environment first: assigning into `sage:::.sage_state$x` directly
  # is not a valid replacement expression.
  st  <- sage:::.sage_state
  old <- st$source
  on.exit({
    st$source  <- old
    st$columns <- NULL
  }, add = TRUE)
  sage_set_source(src)
  force(code)
}

# Live-archive tests are skipped on CRAN and whenever the bucket is not
# reachable, per the CRAN policy on internet resources.
skip_if_no_archive <- function() {
  testthat::skip_on_cran()
  testthat::skip_if_not_installed("curl")
  testthat::skip_if_offline()
  ok <- tryCatch(
    !is.null(suppressWarnings(utils::read.csv(
      "https://storage.googleapis.com/sage-archive/parquet/_index.csv"))),
    error = function(e) FALSE)
  testthat::skip_if_not(isTRUE(ok), "SAGE archive is not reachable")
}
