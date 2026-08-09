# Live-archive tests. Skipped on CRAN and whenever the bucket is unreachable,
# so a check machine without network access still passes.

test_that("the public archive answers the index queries", {
  skip_if_no_archive()
  with_source("gs://sage-archive/parquet", {
    countries <- sage_countries()
    expect_gt(length(countries), 50)
    expect_true("Germany" %in% countries)
    expect_true(2021 %in% sage_years("Germany"))
  })
})

test_that("every spelling of the bucket gives the same columns", {
  skip_if_no_archive()
  ref <- with_source("gs://sage-archive/parquet", sage_columns())
  expect_identical(ref[1:2], c("country", "year"))
  for (src in c("gs://sage-archive/parquet/",
                "https://storage.googleapis.com/sage-archive/parquet",
                "http://storage.googleapis.com/sage-archive/parquet")) {
    expect_identical(with_source(src, sage_columns()), ref)
  }
})

test_that("the GCS reader and the download path agree on a schema", {
  skip_if_no_archive()
  skip_if_not(isTRUE(arrow::arrow_info()$capabilities[["gcs"]]),
              "this arrow build has no GCS support")
  with_source("gs://sage-archive/parquet", {
    # A key with a percent-encoded space is the case most likely to diverge
    # between the two readers.
    relpath <- "country=Bosnia%20and%20Herzegovina/year=2018/part-0.parquet"
    gcs <- sage:::.gcs_handle()
    skip_if(is.null(gcs), "no GCS filesystem available")
    via_gcs <- arrow::ParquetFileReader$create(
      gcs$fs$OpenInputFile(paste0(gcs$root, "/", relpath)))$GetSchema()$names
    tmp <- tempfile(fileext = ".parquet")
    on.exit(unlink(tmp), add = TRUE)
    utils::download.file(sage:::.path_to_url(relpath), tmp, mode = "wb", quiet = TRUE)
    via_download <- names(arrow::open_dataset(tmp, format = "parquet"))
    expect_identical(via_gcs, via_download)
  })
})

test_that("a remote slice round-trips", {
  skip_if_no_archive()
  with_source("gs://sage-archive/parquet", {
    d <- sage_load("Samoa")
    expect_s3_class(d, "tbl_df")
    expect_identical(unique(d$country), "Samoa")
    expect_gt(nrow(d), 0)
    expect_identical(names(d)[1:2], c("country", "year"))
  })
})
