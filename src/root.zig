//! See `SlotMap`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const log = std.log.scoped(.slot_map);

/// Configuration for `SlotMap`.
pub const KeyOptions = struct {
    Index: type = u32,
    GenerationTag: type = u32,
};

/// A high performance associative container. Returns a unique persistent key for each added item.
///
/// Useful for managing objects with runtime known lifetimes, such as entities in a video game,
/// since keys are never "dangling."
///
/// Persistent keys are implemented as indices paired with bit generation counters. Saturated
/// generation counters are not reused, which means that after creating and destroying
/// `capacity * @intFromEnum(Generation.invalid)` entries the slot map will run out of unique keys and
/// return `error.Overflow` on `put`.
///
/// Used internally by `Entities`, exposed publicly as it's a generally useful container. May be
/// moved into separate repo in the future.
///
/// # Example
/// ```zig
/// var slots: SlotMap(u8, []const u8) = try .init(gpa, 100);
/// defer slots.deinit(gpa);
///
/// const key = slots.put("hello, world!");
/// const value = slots.get(key).?;
///
/// slots.remove(key);
/// assert(!slots.containsKey(key));
/// ```
pub fn SlotMap(Val: type, key_options: KeyOptions) type {
    const Generation = enum(key_options.GenerationTag) {
        invalid = 0,
        first = 1,
        _,

        pub fn format(
            self: @This(),
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = fmt;
            _ = options;
            if (self == .invalid) {
                try writer.writeAll(".invalid");
            } else {
                try writer.print("0x{x}", .{@intFromEnum(self)});
            }
        }
    };
    const Index = key_options.Index;

    return struct {
        /// A persistent `SlotMap` key.
        pub const Key = packed struct {
            /// Similar to `Key`, but may be set to `.none`.
            pub const Optional = packed struct {
                pub const none: @This() = .{ .index = 0, .generation = .invalid };

                index: Index,
                generation: Generation,

                /// Unwraps the optional key into `Key`, or returns `null` if it is `.none`.
                pub fn unwrap(self: @This()) ?Key {
                    if (self == none) return null;
                    assert(self.generation != .invalid);
                    return .{
                        .index = self.index,
                        .generation = self.generation,
                    };
                }

                pub fn format(
                    self: @This(),
                    comptime fmt: []const u8,
                    options: std.fmt.FormatOptions,
                    writer: anytype,
                ) !void {
                    _ = fmt;
                    _ = options;
                    if (self.unwrap()) |key| {
                        try writer.print("{}", .{key});
                    } else {
                        try writer.writeAll(".none");
                    }
                }
            };

            /// The key's index. Points to the relevant data.
            index: Index,
            /// The key's generation, used to guarantee key uniqueness.
            generation: Generation,

            /// Returns this key as an optional.
            pub fn toOptional(self: @This()) Optional {
                // Invalid is only allowed on optional keys.
                assert(self.generation != .invalid);
                return .{
                    .index = self.index,
                    .generation = self.generation,
                };
            }

            pub fn format(
                self: @This(),
                comptime fmt: []const u8,
                options: std.fmt.FormatOptions,
                writer: anytype,
            ) !void {
                _ = fmt;
                _ = options;
                assert(self.generation != .invalid);
                try writer.print("0x{x}:{}", .{ self.index, self.generation });
            }
        };

        /// The type of the associated values.
        pub const Value = Val;

        /// A slot in the slot map.
        pub const Slot = struct {
            generation: Generation,
            value: Value,
        };

        /// The max number of values this slot map can hold simultaneously.
        capacity: usize,

        /// The number of slots with saturated generations. For most use cases, the capacity should
        /// be set high enough that this value remains 0.
        saturated: usize,

        slots: []Slot,
        next_index: usize,
        free: []Index,
        free_count: usize,

        /// Initializes a slot map with the given capacity.
        pub fn init(gpa: Allocator, capacity: usize) Allocator.Error!@This() {
            assert(capacity <= std.math.maxInt(Index));
            comptime assert(std.math.maxInt(Index) < std.math.maxInt(usize)); // For `next_index`

            const slots = try gpa.alloc(Slot, capacity);
            errdefer gpa.free(slots);

            const free = try gpa.alloc(Index, capacity);
            errdefer gpa.free(free);

            return .{
                .capacity = capacity,
                .saturated = 0,
                .slots = slots,
                .next_index = 0,
                .free = free,
                .free_count = 0,
            };
        }

        /// Destroys the slot map.
        pub fn deinit(self: *@This(), gpa: Allocator) void {
            gpa.free(self.slots);
            gpa.free(self.free);
            self.* = undefined;
        }

        /// Clears all values and recycles all keys.
        pub fn recycleAll(self: *@This()) void {
            self.* = .{
                .capacity = self.capacity,
                .saturated = 0,
                .slots = self.slots,
                .next_index = 0,
                .free = self.free,
                .free_count = 0,
            };
        }

        /// Inserts an item into the slot map, returning a persistent unique key.
        pub fn put(self: *@This(), value: Value) error{Overflow}!Key {
            const index: Index = if (self.free_count > 0) b: {
                self.free_count -= 1;
                break :b self.free[self.free_count];
            } else b: {
                if (self.next_index >= self.capacity) return error.Overflow;
                const index = self.next_index;
                self.next_index += 1;
                self.slots[index].generation = .first;
                break :b @intCast(index);
            };

            self.slots[index].value = value;

            const generation = self.slots[index].generation;
            assert(generation != .invalid);
            return .{
                .index = index,
                .generation = generation,
            };
        }

        /// Returns true if the value associated with the given key still exists in the map,
        /// false otherwise.
        ///
        /// Asserts that the key was once valid, unless the generation is set to invalid.
        pub fn containsKey(self: @This(), key: Key) bool {
            // Get the current generation
            const gen = self.slots[key.index].generation;

            // Check that this key was once or is currently valid
            assert(key.generation != .invalid);
            assert(key.index < self.next_index);
            assert(gen == .invalid or @intFromEnum(key.generation) <= @intFromEnum(gen));

            // Check if the key is currently valid
            return key.generation == gen;
        }

        /// Retrieves the value associated with the given key, or `null` if it no longer exists.
        pub fn get(self: *const @This(), key: Key) ?*Value {
            if (!self.containsKey(key)) return null;
            return &self.slots[key.index].value;
        }

        /// Removes the value associated with the given key. The key remains valid.
        pub fn remove(self: *@This(), key: Key) void {
            if (!self.containsKey(key)) return;
            self.slots[key.index].generation =
                @enumFromInt(@intFromEnum(self.slots[key.index].generation) +% 1);
            if (self.slots[key.index].generation == .invalid) {
                self.saturated += 1;
            } else {
                self.free[self.free_count] = key.index;
                self.free_count += 1;
            }
        }

        /// Similar to `remove`, but allows the key to be reused in the future.
        pub fn recycle(self: *@This(), key: Key) void {
            if (!self.containsKey(key)) return;
            self.free[self.free_count] = key.index;
            self.free_count += 1;
        }

        /// Returns the number of values currently stored.
        pub fn count(self: @This()) usize {
            return self.next_index - self.free_count - self.saturated;
        }
    };
}

test "slot map" {
    var slots: SlotMap(u8, .{}) = try .init(std.testing.allocator, 3);
    defer slots.deinit(std.testing.allocator);
    try std.testing.expectEqual(0, slots.count());

    try std.testing.expectEqual(null, @TypeOf(slots).Key.Optional.none.unwrap());

    const a = try slots.put('a');
    try std.testing.expectEqual(0, a.index);
    try std.testing.expectEqual(1, @intFromEnum(a.generation));
    try std.testing.expectEqual(1, slots.count());

    const b = try slots.put('b');
    try std.testing.expectEqual(1, b.index);
    try std.testing.expectEqual(1, @intFromEnum(b.generation));
    try std.testing.expectEqual(2, slots.count());

    const c = try slots.put('c');
    try std.testing.expectEqual(2, c.index);
    try std.testing.expectEqual(1, @intFromEnum(c.generation));
    try std.testing.expectEqual(3, slots.count());

    try std.testing.expectEqual('a', slots.get(a).?.*);
    try std.testing.expectEqual('b', slots.get(b).?.*);
    try std.testing.expectEqual('c', slots.get(c).?.*);

    try std.testing.expect(a == a);
    try std.testing.expect(a != b);
    try std.testing.expect(a != c);
    try std.testing.expect(b != c);
    try std.testing.expect(a.toOptional() != @TypeOf(slots).Key.Optional.none);
    try std.testing.expect(a.toOptional().unwrap().? == a);

    try std.testing.expectError(error.Overflow, slots.put('d'));

    try std.testing.expect(slots.containsKey(a));
    slots.remove(a);
    try std.testing.expectEqual(2, slots.count());
    try std.testing.expect(!slots.containsKey(a));
    slots.remove(a);
    try std.testing.expectEqual(2, slots.count());
    try std.testing.expect(!slots.containsKey(a));

    slots.remove(c);
    try std.testing.expectEqual(1, slots.count());
    try std.testing.expect(!slots.containsKey(a));
    try std.testing.expect(slots.containsKey(b));
    try std.testing.expect(!slots.containsKey(c));

    try std.testing.expectEqual(null, slots.get(a));
    try std.testing.expectEqual('b', slots.get(b).?.*);
    try std.testing.expectEqual(null, slots.get(c));

    try std.testing.expect(a == a);
    try std.testing.expect(a != b);
    try std.testing.expect(a != c);
    try std.testing.expect(b != c);

    const d = try slots.put('d');
    try std.testing.expectEqual(2, d.index);
    try std.testing.expectEqual(2, @intFromEnum(d.generation));
    try std.testing.expectEqual(2, slots.count());

    try std.testing.expect(d != a);
    try std.testing.expect(a != b);
    try std.testing.expect(d != c);
    try std.testing.expect(d == d);

    const e = try slots.put('e');
    try std.testing.expectEqual(0, e.index);
    try std.testing.expectEqual(2, @intFromEnum(e.generation));
    try std.testing.expectEqual(3, slots.count());

    try std.testing.expectError(error.Overflow, slots.put('f'));

    try std.testing.expectEqual(null, slots.get(a));
    try std.testing.expectEqual('b', slots.get(b).?.*);
    try std.testing.expectEqual(null, slots.get(c));
    try std.testing.expectEqual('d', slots.get(d).?.*);
    try std.testing.expectEqual('e', slots.get(e).?.*);

    // Make sure we ignore slots whose generations wrap
    slots.remove(b);
    slots.remove(d);
    slots.remove(e);
    try std.testing.expectEqual(0, slots.count());
    slots.slots[b.index].generation = @enumFromInt(std.math.maxInt(u32) - 1);
    slots.slots[d.index].generation = @enumFromInt(std.math.maxInt(u32) - 1);
    slots.slots[e.index].generation = @enumFromInt(std.math.maxInt(u32) - 1);

    try std.testing.expectEqual(0, slots.saturated);

    for (0..2) |_| {
        const e_new = try slots.put('z');
        try std.testing.expectEqual(1, slots.count());
        try std.testing.expectEqual(e.index, e_new.index);
        slots.remove(e_new);
        try std.testing.expectEqual(0, slots.count());
        try std.testing.expect(!slots.containsKey(e_new));
    }
    try std.testing.expectEqual(1, slots.saturated);

    for (0..2) |_| {
        const d_new = try slots.put('z');
        try std.testing.expectEqual(1, slots.count());
        try std.testing.expectEqual(d.index, d_new.index);
        slots.remove(d_new);
        try std.testing.expectEqual(0, slots.count());
        try std.testing.expect(!slots.containsKey(d_new));
    }
    try std.testing.expectEqual(2, slots.saturated);

    for (0..2) |_| {
        const b_new = try slots.put('z');
        try std.testing.expectEqual(1, slots.count());
        try std.testing.expectEqual(b.index, b_new.index);
        slots.remove(b_new);
        try std.testing.expectEqual(0, slots.count());
        try std.testing.expect(!slots.containsKey(b_new));
    }
    try std.testing.expectEqual(3, slots.saturated);
    try std.testing.expectEqual(0, slots.count());

    try std.testing.expectError(error.Overflow, slots.put('z'));

    slots.recycleAll();
    try std.testing.expectEqual(3, slots.capacity);
    try std.testing.expectEqual(0, slots.saturated);
    try std.testing.expectEqual(0, slots.count());
}

test "recycle key" {
    var slots: SlotMap(u8, .{}) = try .init(std.testing.allocator, 3);
    defer slots.deinit(std.testing.allocator);
    try std.testing.expectEqual(0, slots.count());

    try std.testing.expectEqual(null, @TypeOf(slots).Key.Optional.none.unwrap());

    const a = try slots.put('a');
    try std.testing.expectEqual(0, a.index);
    try std.testing.expectEqual(1, @intFromEnum(a.generation));
    try std.testing.expectEqual(1, slots.count());

    slots.recycle(a);

    const b = try slots.put('b');
    try std.testing.expectEqual(0, b.index);
    try std.testing.expectEqual(1, @intFromEnum(b.generation));
    try std.testing.expectEqual(1, slots.count());

    const c = try slots.put('c');
    try std.testing.expectEqual(1, c.index);
    try std.testing.expectEqual(1, @intFromEnum(c.generation));
    try std.testing.expectEqual(2, slots.count());
}

// Basically just making sure it compiles
test "format key" {
    const Key = SlotMap(void, .{}).Key;
    const Generation = @FieldType(Key, "generation");
    try std.testing.expectFmt("0xa:0xb", "{}", .{Key{
        .index = 10,
        .generation = @enumFromInt(11),
    }});
    try std.testing.expectFmt("0xa:0xb", "{}", .{(Key{
        .index = 10,
        .generation = @enumFromInt(11),
    }).toOptional()});
    try std.testing.expectFmt(".invalid", "{}", .{Generation.invalid});
    try std.testing.expectFmt(".none", "{}", .{Key.Optional.none});
}
