module ecsd.entity;

/// The raw type used to reference any given entity.
struct EntityID
{
	alias EID = uint;
	alias UID = ushort;
	alias Serial = ushort;
	
	/++
		The entity-specific portion of this id. Unique within a given `ecsd.universe.Universe`,
		but not between universes.
	+/
    EID id;
	
	/++
		The id of the `ecsd.universe.Universe` that owns this entity.
	+/
    UID uid;
	
	/++
		A counter of how many times `id` has been reused in the owning `ecsd.universe.Universe`.
		
		This is used to verify that references held to any
		entity are in fact referring to the same entity, and not some unrelated entity that happens
		to have the same `id`.
	+/
    Serial serial;
}

/++
	Wrapper type around `EntityID` for both convenience and safety.
	
	In debug builds, all methods explicitly check that the referenced entity is still alive.
+/
struct Entity
{
	import ecsd.universe: Universe, findUniverse;
	
	private static immutable invalidMessage = "Use of Entity handle after associated entity freed";
	
	private EntityID _id;
	private Universe _uni;
	
	invariant(_id.uid == _uni.id);
	
	@disable this();
	
	/// Wrap an `EntityID`. If unspecified, will find the owning `ecsd.universe.Universe` from the given id.
	this(EntityID id)
	{
		_id = id;
		_uni = findUniverse(id.uid);
	}
	
	/// ditto
	this(EntityID id, Universe uni)
	{
		_id = id;
		_uni = uni;
	}
	
	/// Returns whether entity is valid. Allows use in `if(T x = ...)` expresions.
	bool opCast(T: bool)() const
	{
		return valid;
	}
	
	/// Returns the raw `EntityID`.
	EntityID id()
	{
		return _id;
	}
	
	/// Returns owning `ecsd.universe.Universe`.
	Universe universe()
	{
		return _uni;
	}
	
	/// Checks whether this entity is still alive in its owning universe.
	bool valid() const
	{
		return _uni !is null && _uni.isEntityAlive(_id);
	}
	
	/// Returns whether this entity has the given component type.
	bool has(Component)() const
	in(valid, invalidMessage)
	{
		return _uni.getStorage!Component.has(_id);
	}
	
	/++
		Adds a component of the given type to this entity, optionally passing an instance to copy from.
		
		Returns: reference to the newly allocated component.
	+/
	ref Component add(Component)(Component inst = Component.init)
	in(valid, invalidMessage)
	{
		return _uni.getStorage!Component.add(_id, inst);
	}
	
	/// Removes component of the given type from this entity.
	void remove(Component)()
	in(valid, invalidMessage)
	{
		return _uni.getStorage!Component.remove(_id);
	}
	
	/// Returns a reference to this entity's instance of the given component type.
	ref Component get(Component)()
	in(valid, invalidMessage)
	{
		return _uni.getStorage!Component.get(_id);
	}
	
	/// Frees this entity in its owning universe. Shortcut for `Universe.freeEntity`.
	void free()
	in(valid, invalidMessage)
	out(; !valid)
	{
		_uni.freeEntity(_id);
	}
}

unittest
{
	import std.exception;
	import ecsd.universe;
	
	static struct TestComponent {}
	
	auto uni = allocUniverse();
	scope(exit) freeUniverse(uni);
	uni.registerComponent!TestComponent;
	
	auto ent = Entity(uni.allocEntity, uni);
	ent.has!TestComponent; // ensure does not throw
	assert(ent.valid);
	ent.free;
	assertThrown!Throwable(ent.has!TestComponent);
}
