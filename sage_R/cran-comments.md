# cran-comments

## Test environments

* Windows 11, R 4.3.1 (local): 0 errors, 0 warnings, 2 notes

The two local notes are both environmental rather than package problems:
`unable to verify current time` (the check machine could not reach a time
server) and `Files 'README.md' or 'NEWS.md' cannot be checked without 'pandoc'
being installed`.

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

## Reverse dependencies

None; this is a new submission.
