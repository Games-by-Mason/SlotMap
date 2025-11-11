# SlotMap
A high performance associative container. Returns a unique persistent key for each added item.

Useful for managing objects with runtime known lifetimes, such as entities in a video game,
since keys are never "dangling."

Persistent keys are implemented as indices paired with bit generation counters. Saturated
generation counters are not reused, which means that after creating and destroying
`capacity * @intFromEnum(Generation.invalid)` entries the slot map will run out of unique keys and
return `error.Overflow` on `put`.

Inspired by [SergeyMakeev/slot_map](https://github.com/SergeyMakeev/slot_map).

Documentation available [here](https://docs.gamesbymason.com/slot_map/), you can generate up to date docs yourself with `zig build docs`.

# Example
```zig
var slots: SlotMap(u8, []const u8) = try .init(gpa, 100);
defer slots.deinit(gpa);

const key = slots.put("hello, world!");
const value = slots.get(key).?;

slots.remove(key);
assert(!slots.exists(key));
```
