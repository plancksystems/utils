
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const FieldType = enum(u8) {
    string = 1,
    int = 2,
    double = 3,
    bool = 4,
    datetime = 5,
    objectid = 6,

    pub fn fromString(s: []const u8) ?FieldType {
        if (std.mem.eql(u8, s, "string")) return .string;
        if (std.mem.eql(u8, s, "int")) return .int;
        if (std.mem.eql(u8, s, "double")) return .double;
        if (std.mem.eql(u8, s, "bool")) return .bool;
        if (std.mem.eql(u8, s, "datetime")) return .datetime;
        if (std.mem.eql(u8, s, "objectid")) return .objectid;
        return null;
    }

    pub fn toString(self: FieldType) []const u8 {
        return switch (self) {
            .string => "string",
            .int => "int",
            .double => "double",
            .bool => "bool",
            .datetime => "datetime",
            .objectid => "objectid",
        };
    }
};

pub const FileRole = enum(u8) {
    parent = 1,
    child = 2,

    pub fn fromString(s: []const u8) ?FileRole {
        if (std.mem.eql(u8, s, "parent")) return .parent;
        if (std.mem.eql(u8, s, "child")) return .child;
        return null;
    }

    pub fn toString(self: FileRole) []const u8 {
        return switch (self) {
            .parent => "parent",
            .child => "child",
        };
    }
};

pub const ExportFormat = enum(u8) {
    bson = 1,
    json = 2,
    csv = 3,

    pub fn fromString(s: []const u8) ?ExportFormat {
        if (std.mem.eql(u8, s, "bson")) return .bson;
        if (std.mem.eql(u8, s, "json")) return .json;
        if (std.mem.eql(u8, s, "csv")) return .csv;
        return null;
    }

    pub fn toString(self: ExportFormat) []const u8 {
        return switch (self) {
            .bson => "bson",
            .json => "json",
            .csv => "csv",
        };
    }
};

pub const FieldDescriptor = struct {
    name: []const u8,
    field_type: FieldType,
};

pub const ExportFileEntry = struct {
    name: []const u8,
    role: FileRole,
    parent: ?[]const u8 = null,
    link_field: ?[]const u8 = null,
    injected_fields: ?[]const []const u8 = null,
    fields: []const []const u8,
};

pub const ExportManifest = struct {
    source: []const u8,
    format: ExportFormat,
    files: []const ExportFileEntry,

    pub fn deinit(self: *ExportManifest, allocator: Allocator) void {
        for (self.files) |entry| {
            allocator.free(entry.name);
            if (entry.parent) |p| allocator.free(p);
            if (entry.link_field) |lf| allocator.free(lf);
            if (entry.injected_fields) |ifs| {
                for (ifs) |f| allocator.free(f);
                allocator.free(ifs);
            }
            for (entry.fields) |f| allocator.free(f);
            allocator.free(entry.fields);
        }
        allocator.free(self.files);
        allocator.free(self.source);
    }
};

pub const ImportSourceEntry = struct {
    name: ?[]const u8 = null,
    file: []const u8,
    role: FileRole,
    parent: ?[]const u8 = null,
    embed_as: ?[]const u8 = null,
    join_key: ?[]const u8 = null,
    fields: []const FieldDescriptor,
};

pub const ImportSpec = struct {
    target: []const u8,
    format: ExportFormat,
    file_path: ?[]const u8 = null,
    sources: ?[]const ImportSourceEntry = null,
    fields: ?[]const FieldDescriptor = null,

    pub fn deinit(self: *ImportSpec, allocator: Allocator) void {
        allocator.free(self.target);
        if (self.file_path) |fp| allocator.free(fp);
        if (self.fields) |fields| {
            for (fields) |fd| allocator.free(fd.name);
            allocator.free(fields);
        }
        if (self.sources) |sources| {
            for (sources) |entry| {
                if (entry.name) |n| allocator.free(n);
                allocator.free(entry.file);
                if (entry.parent) |p| allocator.free(p);
                if (entry.embed_as) |ea| allocator.free(ea);
                if (entry.join_key) |jk| allocator.free(jk);
                for (entry.fields) |fd| allocator.free(fd.name);
                allocator.free(entry.fields);
            }
            allocator.free(sources);
        }
    }

    pub fn findParent(self: *const ImportSpec) ?*const ImportSourceEntry {
        if (self.sources) |sources| {
            for (sources) |*entry| {
                if (entry.role == .parent) return entry;
            }
        }
        return null;
    }

    pub fn findChildren(self: *const ImportSpec, allocator: Allocator, parent_name: []const u8) ![]const *const ImportSourceEntry {
        var result = std.ArrayList(*const ImportSourceEntry).empty;
        errdefer result.deinit(allocator);

        if (self.sources) |sources| {
            for (sources) |*entry| {
                if (entry.role != .child) continue;

                if (entry.parent) |p| {
                    if (std.mem.eql(u8, p, parent_name)) {
                        try result.append(allocator, entry);
                    }
                } else {
                    if (self.findParent()) |pe| {
                        if (pe.name) |pn| {
                            if (std.mem.eql(u8, pn, parent_name)) {
                                try result.append(allocator, entry);
                            }
                        }
                    }
                }
            }
        }

        return try result.toOwnedSlice(allocator);
    }

    pub fn buildOrder(self: *const ImportSpec, allocator: Allocator) ![]const *const ImportSourceEntry {
        if (self.sources == null) return &[_]*const ImportSourceEntry{};

        var ordered = std.ArrayList(*const ImportSourceEntry).empty;
        errdefer ordered.deinit(allocator);

        var visited = std.StringHashMap(bool).init(allocator);
        defer visited.deinit();

        if (self.findParent()) |parent_entry| {
            try self.buildOrderRecursive(allocator, parent_entry, &ordered, &visited);
        }

        return try ordered.toOwnedSlice(allocator);
    }

    fn buildOrderRecursive(self: *const ImportSpec, allocator: Allocator, entry: *const ImportSourceEntry, ordered: *std.ArrayList(*const ImportSourceEntry), visited: *std.StringHashMap(bool)) !void {
        const entry_name = entry.name orelse entry.file;
        if (visited.contains(entry_name)) return;

        const children = try self.findChildren(allocator, entry_name);
        defer allocator.free(children);

        for (children) |child| {
            try self.buildOrderRecursive(allocator, child, ordered, visited);
        }

        try ordered.append(allocator, entry);
        try visited.put(entry_name, true);
    }
};

pub const EntityDef = struct {
    name: []const u8,
    role: FileRole,
    file: []const u8,
    parent: ?[]const u8 = null,
    parent_field: ?[]const u8 = null,
    join_key: ?[]const u8 = null,
    fields: []const FieldDescriptor,
};

pub const EximManifest = struct {
    store: []const u8,
    format: ExportFormat,
    output_dir: ?[]const u8 = null,
    query: ?[]const u8 = null,
    entities: []const EntityDef,

    pub fn deinit(self: *EximManifest, allocator: Allocator) void {
        allocator.free(self.store);
        if (self.output_dir) |od| allocator.free(od);
        if (self.query) |q| allocator.free(q);
        for (self.entities) |entity| {
            allocator.free(entity.name);
            allocator.free(entity.file);
            if (entity.parent) |p| allocator.free(p);
            if (entity.parent_field) |pf| allocator.free(pf);
            if (entity.join_key) |jk| allocator.free(jk);
            for (entity.fields) |fd| allocator.free(fd.name);
            allocator.free(entity.fields);
        }
        allocator.free(self.entities);
    }

    pub fn findRoot(self: *const EximManifest) ?*const EntityDef {
        for (self.entities) |*e| {
            if (e.role == .parent) return e;
        }
        return null;
    }

    pub fn findChildren(self: *const EximManifest, allocator: Allocator, parent_name: []const u8) ![]const *const EntityDef {
        var result = std.ArrayList(*const EntityDef).empty;
        errdefer result.deinit(allocator);

        const root = self.findRoot();

        for (self.entities) |*e| {
            if (e.role != .child) continue;
            if (e.parent) |p| {
                if (std.mem.eql(u8, p, parent_name)) {
                    try result.append(allocator, e);
                }
            } else {
                if (root) |r| {
                    if (std.mem.eql(u8, r.name, parent_name)) {
                        try result.append(allocator, e);
                    }
                }
            }
        }

        return try result.toOwnedSlice(allocator);
    }

    pub fn toImportSpec(self: *const EximManifest, allocator: Allocator) !ImportSpec {
        const target = try allocator.dupe(u8, self.store);
        errdefer allocator.free(target);

        if (self.format == .bson or self.format == .json) {
            const root = self.findRoot();
            const file_name = if (root) |r| r.file else switch (self.format) {
                .bson => "export.bson",
                .json => "export.json",
                else => unreachable,
            };
            const file_path = if (self.output_dir) |od|
                try std.fmt.allocPrint(allocator, "{s}/{s}", .{ od, file_name })
            else
                try allocator.dupe(u8, file_name);

            return ImportSpec{
                .target = target,
                .format = self.format,
                .file_path = file_path,
            };
        }

        var sources = std.ArrayList(ImportSourceEntry).empty;
        errdefer {
            for (sources.items) |entry| {
                if (entry.name) |n| allocator.free(n);
                allocator.free(entry.file);
                if (entry.parent) |p| allocator.free(p);
                if (entry.embed_as) |ea| allocator.free(ea);
                if (entry.join_key) |jk| allocator.free(jk);
                for (entry.fields) |fd| allocator.free(fd.name);
                allocator.free(entry.fields);
            }
            sources.deinit(allocator);
        }

        for (self.entities) |entity| {
            const file_path = if (self.output_dir) |od| blk: {
                break :blk try std.fmt.allocPrint(allocator, "{s}/{s}", .{ od, entity.file });
            } else try allocator.dupe(u8, entity.file);

            var fields = try allocator.alloc(FieldDescriptor, entity.fields.len);
            for (entity.fields, 0..) |fd, i| {
                fields[i] = .{
                    .name = try allocator.dupe(u8, fd.name),
                    .field_type = fd.field_type,
                };
            }

            try sources.append(allocator, .{
                .name = try allocator.dupe(u8, entity.name),
                .file = file_path,
                .role = entity.role,
                .parent = if (entity.parent) |p| try allocator.dupe(u8, p) else null,
                .embed_as = if (entity.parent_field) |pf| try allocator.dupe(u8, pf) else null,
                .join_key = if (entity.join_key) |jk| try allocator.dupe(u8, jk) else null,
                .fields = fields,
            });
        }

        return ImportSpec{
            .target = target,
            .format = self.format,
            .sources = try sources.toOwnedSlice(allocator),
        };
    }
};

pub const ManifestParseError = error{
    MissingStore,
    MissingFormat,
    InvalidFormat,
    InvalidRole,
    InvalidFieldType,
    MissingEntityName,
    MissingEntityRole,
    MissingEntityFile,
    OutOfMemory,
};

// The YAML codec for these manifest types lives in
// `planck/db/src/exim/manifest_yaml.zig`. It uses the `yaml` package and
// produces values of the types defined above. Kept out of `utils` so the
// crate stays dependency-free.
