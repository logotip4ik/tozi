pub inline fn assert(ok: bool) void {
    if (!ok) unreachable;
}
