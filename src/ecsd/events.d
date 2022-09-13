///
module ecsd.events;

import ecsd.entity: Entity, Spawned;
import ecsd.universe: Universe;

/// Published when a `Universe` is allocated.
struct UniverseAllocated
{
	Universe universe; ///
}

/// Published when a `Universe` is freed.
struct UniverseFreed
{
	Universe universe; ///
}

/// Published when the given component type is registered to a universe.
struct ComponentRegistered(Component)
{
	Universe universe; ///
}

/// Published when the given component type is deregistered from a universe.
struct ComponentDeregistered(Component)
{
	Universe universe; ///
}

/// Published when the given component type has been added to an entity.
struct ComponentAdded(Component)
{
	Entity entity; ///
	Component* component; ///
}

/// Published when the given component type has been removed from an entity.
struct ComponentRemoved(Component)
{
	Entity entity; ///
	Component* component; ///
}

/// Published when an entity is allocated.
struct EntityAllocated
{
	Entity entity; ///
}

/// Published when an entity is freed.
struct EntityFreed
{
	Entity entity; ///
}

/// Shortcut for `ComponentAdded!ecsd.entity.Spawned`.
struct EntitySpawned
{
	ComponentAdded!Spawned inner;
	alias inner this;
}

/// Shortcut for `ComponentRemoved!ecsd.entity.Spawned`.
struct EntityDespawned
{
	ComponentRemoved!Spawned inner;
	alias inner this;
}
