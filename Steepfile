# Checks lib/ against sig/, which rbs-inline writes from the comments in
# lib/, and sig-deps/, which corrects core signatures and is not shipped.
# hegeltest and prism ship RBS of their own, so Steep reads theirs.
target :lib do
  signature "sig", "sig-deps"
  check "lib"

  library "etc", "json", "open3", "shellwords", "tmpdir", "prism", "hegeltest"
end
