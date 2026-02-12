pub const Operation = union(enum) {
    read,
    write,
    timer: u32,
};

