// Server-side unit tests. Aggregated at the `src/` level so the modules under
// `tms/` may import their `../common/` siblings (a test root can only import
// within its own directory subtree).

test {
    _ = @import("tms/xtest.zig");
}
