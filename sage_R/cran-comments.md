# cran-comments

## Resubmission

The first submission failed the incoming pretest on Debian R-devel: the
examples and tests could not read the Parquet files shipped in
`inst/extdata`, because they were zstd-compressed and the check machine's
arrow build does not include zstd. The shipped excerpt is now written
uncompressed, which every arrow build can read. Its contents are unchanged.

## Test environments

* Windows 11, R 4.3.1 (local): 0 errors, 0 warnings, 2 notes

The notes are the new-submission note and `unable to verify current time`
(the check machine could not reach a time server).

## Internet resources

The package reads a public Google Cloud Storage bucket. Per the CRAN policy on
internet resources:

* Every example runs against a 26 KB excerpt of the archive shipped in
  `inst/extdata`, so no example needs network access. Examples that would use
  the live archive are wrapped in `\dontrun{}`.
* Tests against the live archive call `skip_on_cran()`, `skip_if_offline()`,
  and an explicit reachability check before doing anything. The offline test
  suite covers the same code paths against the shipped excerpt.
* A source that cannot be read fails with a message naming the source and, for
  a remote source, saying it may be temporarily unreachable.

`\dontrun{}` rather than `\donttest{}` is deliberate for the live-archive
examples. Each one transfers a real election partition (tens to hundreds of
MB), so running them on the check machines would mean a large download per
check rather than a quick call. The same code paths are exercised by the
runnable examples and the offline tests against the shipped excerpt. If you
would prefer `\donttest{}` we are happy to switch.

## Reverse dependencies

None; this is a new submission.
