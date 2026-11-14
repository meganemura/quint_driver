# Checks lib/ against sig/, which rbs-inline writes from the comments in
# lib/. hegeltest and prism ship RBS of their own, so Steep reads theirs.
target :lib do
  signature "sig"
  check "lib"

  library "etc", "json", "open3", "shellwords", "tmpdir", "prism", "hegeltest"
end
