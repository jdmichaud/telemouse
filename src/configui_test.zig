// Test anchor for the config UI. Its module root is `src/`, so configui's
// cross-directory imports (`../common/...`) resolve within the module. Building
// configui.zig directly as a test root would place the boundary at `src/ui/`
// and reject those imports.

test {
    _ = @import("ui/configui.zig");
}
