test_that("sage_set_source() validates its argument", {
  expect_error(sage_set_source(character(0)))
  expect_error(sage_set_source(""))
  expect_error(sage_set_source(c("a", "b")))
  expect_error(sage_set_source(42))
})

test_that("sage_set_source() returns the source invisibly", {
  with_source(mini(), {
    expect_invisible(sage_set_source(mini()))
    expect_identical(sage_set_source(mini()), mini())
  })
})

test_that("a trailing slash on a remote source is dropped", {
  with_source("gs://sage-archive/parquet/", {
    expect_identical(sage:::.sage_source(), "gs://sage-archive/parquet")
  })
  with_source("https://example.com/sage//", {
    expect_identical(sage:::.sage_source(), "https://example.com/sage")
  })
})

test_that("a local path keeps its trailing slash", {
  # Local paths go through file.path(), which handles the separator itself;
  # stripping here would break a source that is a bare drive or mount root.
  with_source("/data/sage/", {
    expect_identical(sage:::.sage_source(), "/data/sage/")
  })
})

test_that("remote sources are recognized by scheme", {
  expect_true(sage:::.is_remote("gs://bucket/x"))
  expect_true(sage:::.is_remote("https://example.com/x"))
  expect_true(sage:::.is_remote("http://example.com/x"))
  expect_false(sage:::.is_remote("/data/sage"))
  expect_false(sage:::.is_remote("C:/data/sage"))
})

test_that("gs:// sources resolve to the HTTPS bucket base", {
  with_source("gs://sage-archive/parquet", {
    expect_identical(sage:::.https_base(),
                     "https://storage.googleapis.com/sage-archive/parquet")
    expect_identical(sage:::.archive_root_https(),
                     "https://storage.googleapis.com/sage-archive")
  })
})

test_that("index paths are percent-escaped once for HTTP", {
  # _index.csv already stores Arrow's encoding, so the literal '%' has to be
  # escaped again to reach the right object key.
  expect_identical(
    sage:::.path_to_url("country=Bosnia%20and%20Herzegovina/year=2018/part-0.parquet",
                        base = "https://host/p"),
    "https://host/p/country=Bosnia%2520and%2520Herzegovina/year=2018/part-0.parquet")
  expect_identical(sage:::.path_to_url("country=Iceland/year=2020/part-0.parquet",
                                       base = "https://host/p"),
                   "https://host/p/country=Iceland/year=2020/part-0.parquet")
})

test_that("an unreadable source gives an informative error", {
  with_source(file.path(tempdir(), "no-such-archive"), {
    expect_error(sage_countries(), "could not read the SAGE archive")
    expect_error(sage_countries(), "contains _index.csv")
  })
  with_source("https://sage.invalid/parquet", {
    expect_error(suppressWarnings(sage_countries()), "may be temporarily unreachable")
  })
})
