// INFO: try to not forget to update info in help command when changing operations
pub const OpType = enum {
    plus,
    minus,
    star,
    slash,
    percent,
    neg,
    abs,
    min,
    max,
    dup,
    swap,
    drop,
    over,
    rot,
    clear,
    print,
    peek,
    stack,
    vars,
    quit,
    help,
};

pub const Token = union(enum) {
    int: i32,
    float: f64,
    bool: bool,
    op: OpType,
    set_var: []const u8,
    get_var: []const u8,
};
