///
module ecsd.entity;

/// The raw type used to reference any given entity.
struct EntityID
{
	/++
		The types of each part of this full entity ID.
		
		For use in storages and other places where partial IDs are needed.
	+/
	alias EID = uint;
	
	/// ditto
	alias UID = ushort;
	
	/// ditto
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
	inout(EntityID) id() inout
	{
		return _id;
	}
	alias id this;
	
	/// Returns owning `ecsd.universe.Universe`.
	inout(Universe) universe() inout
	{
		return _uni;
	}
	
	/++
		Returns whether this entity is still alive.
	+/
	bool valid() const
	{
		return _uni !is null && _uni.isEntityAlive(_id);
	}
	
	/++
		Returns whether this entity has `Component`.
		
		Shortcut for `ecsd.storage.Storage.has`.
	+/
	bool has(Component)() const
	in(valid, invalidMessage)
	{
		return _uni.getStorage!Component.has(_id);
	}
	
	/++
		Attaches `Component` to this entity, copied from the provided instance if any.
		
		Shortcut for `ecsd.storage.Storage.add`.
		
		Returns: pointer to the newly allocated `Component`.
	+/
	Component* add(Component)(Component inst = Component.init)
	in(valid, invalidMessage)
	{
		return _uni.getStorage!Component.add(_id, inst);
	}
	
	/++
		Removes `Component` from this entity.
		
		Shortcut for `ecsd.storage.Storage.remove`.
	+/
	void remove(Component)()
	in(valid, invalidMessage)
	{
		return _uni.getStorage!Component.remove(_id);
	}
	
	/++
		Returns a (never null) pointer to this entity's instance of `Component`.
		
		Shortcut for `ecsd.storage.Storage.get`.
	+/
	Component* get(Component)() inout
	in(valid, invalidMessage)
	{
		return _uni.getStorage!Component.get(_id);
	}
	
	/++
		Like `get`, returns a pointer to this entity's `Component`. Unlike `get`, when this entity
		has no such component a null pointer will be returned.
		
		Shortcut for `ecsd.storage.Storage.tryGet`.
	+/
	Component* tryGet(Component)() inout
	in(valid, invalidMessage)
	{
		return _uni.getStorage!Component.tryGet(_id);
	}
	
	/++
		Frees this entity in its owning universe.
		
		Shortcut for `Universe.freeEntity`.
	+/
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
