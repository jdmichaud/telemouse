// Test anchor for the client session logic. Its module root is `src/`, so
// session's cross-directory imports (`../common/...`) resolve within the module.

test {
    _ = @import("tmc/session.zig");
}
