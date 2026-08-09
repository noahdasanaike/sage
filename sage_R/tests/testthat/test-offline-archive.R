# These run against the excerpt in inst/extdata and need no network access.

test_that("sage_countries() lists the excerpt's countries", {
  with_source(mini(), {
    expect_identical(sage_countries(), c("Iceland", "Samoa"))
  })
})

test_that("sage_years() is per-country and sorted", {
  with_source(mini(), {
    expect_identical(sage_years("Iceland"), c(1968L, 2020L))
    expect_identical(sage_years("Samoa"), 2025L)
    expect_length(sage_years("Nowhere"), 0)
  })
})

test_that("sage_columns() returns the union across partitions", {
  with_source(mini(), {
    cols <- sage_columns()
    expect_type(cols, "character")
    expect_identical(cols[1:2], c("country", "year"))
    # Samoa carries columns Iceland does not, so the union must exceed either.
    is_cols <- names(sage_load("Iceland", years = 2020, drop_all_na = FALSE))
    expect_true(all(is_cols %in% cols))
    expect_gt(length(cols), length(is_cols))
    expect_false(anyDuplicated(cols) > 0)
  })
})

test_that("sage_load() returns a tibble keyed by country and year", {
  with_source(mini(), {
    d <- sage_load("Iceland", years = 2020)
    expect_s3_class(d, "tbl_df")
    expect_identical(names(d)[1:2], c("country", "year"))
    expect_identical(unique(d$country), "Iceland")
    expect_identical(unique(d$year), 2020L)
    expect_gt(nrow(d), 0)
  })
})

test_that("sage_load() concatenates years when none are given", {
  with_source(mini(), {
    all_yr <- sage_load("Iceland")
    expect_setequal(unique(all_yr$year), c(1968L, 2020L))
    expect_identical(nrow(all_yr),
                     nrow(sage_load("Iceland", years = 1968)) +
                       nrow(sage_load("Iceland", years = 2020)))
  })
})

test_that("sage_load() honors the columns argument and always keeps the keys", {
  with_source(mini(), {
    d <- sage_load("Iceland", years = 2020, columns = "party")
    expect_setequal(names(d), c("country", "year", "party"))
    # An unknown column is ignored rather than an error, since the union
    # schema is not populated for every country.
    d2 <- sage_load("Iceland", years = 2020, columns = c("party", "no_such_column"))
    expect_setequal(names(d2), c("country", "year", "party"))
  })
})

test_that("drop_all_na removes columns that never apply to the slice", {
  with_source(mini(), {
    kept    <- names(sage_load("Iceland", years = 2020, drop_all_na = TRUE))
    dropped <- names(sage_load("Iceland", years = 2020, drop_all_na = FALSE))
    expect_true(all(kept %in% dropped))
    expect_lte(length(kept), length(dropped))
  })
})

test_that("sage_load() validates its arguments", {
  with_source(mini(), {
    expect_error(sage_load(c("Iceland", "Samoa")))
    expect_error(sage_load(1))
    expect_error(sage_load("Iceland", min_match_confidence = "excellent"),
                 "must be one of")
  })
})

test_that("min_match_confidence is a floor, not an exact match", {
  with_source(mini(), {
    d <- sage_load("Samoa", drop_all_na = FALSE)
    skip_if_not(any(!is.na(d$match_confidence)),
                "the excerpt has no populated match_confidence")
    n_high <- nrow(sage_load("Samoa", min_match_confidence = "high"))
    n_med  <- nrow(sage_load("Samoa", min_match_confidence = "medium"))
    n_low  <- nrow(sage_load("Samoa", min_match_confidence = "low"))
    expect_lte(n_high, n_med)
    expect_lte(n_med, n_low)
  })
})

test_that("sage_preference_votes() rejects countries with no sidecar", {
  with_source(mini(), {
    expect_error(sage_preference_votes("Iceland"), "no preference-vote sidecar")
    expect_error(sage_preference_votes("Iceland"), "Germany")
  })
})

test_that("election_type filters the slice", {
  with_source(mini(), {
    expect_identical(unique(sage_load("Samoa", election_type = "Legislative")$election_type),
                     "Legislative")
    expect_identical(nrow(sage_load("Samoa", election_type = "Nonexistent")), 0L)
  })
})

test_that("a country the source does not have is an error", {
  with_source(mini(), {
    expect_error(sage_load("Narnia"), "no data for country")
    expect_error(sage_load("Iceland", years = 1800), "in year", fixed = TRUE)
  })
})

test_that("the local read keeps columns only one partition carries", {
  # Arrow's dataset schema comes from a single fragment, so reading the
  # excerpt as one dataset would drop Samoa's candidate-level columns.
  with_source(mini(), {
    sam <- sage_load("Samoa", drop_all_na = FALSE)
    expect_true(all(c("candidate", "NAME2", "party_b") %in% names(sam)))
    ice <- sage_load("Iceland", years = 2020, drop_all_na = FALSE)
    expect_true("NAME1_b" %in% names(ice))
  })
})
