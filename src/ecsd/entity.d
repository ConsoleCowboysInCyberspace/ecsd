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
	EID id = cast(EID)-1;
	
	/++
		The id of the `ecsd.universe.Universe` that owns this entity.
	+/
	UID uid = cast(UID)-1;
	
	/++
		A counter of how many times `id` has been reused in the owning `ecsd.universe.Universe`.
		
		This is used to verify that references held to any
		entity are in fact referring to the same entity, and not some unrelated entity that happens
		to have the same `id`.
	+/
	Serial serial = cast(Serial)-1;
	
	@disable this(EID);
	@disable this(EID, UID, Serial);
	
	package this(EID id, UID uid)
	{
		this.id = id;
		this.uid = uid;
		serial = 0;
	}
}

/++
	Wrapper type around `EntityID` for both convenience and safety.
	
	In debug builds, all methods explicitly check that the referenced entity is still alive.
+/
struct Entity
{
	import ecsd.event: isEvent;
	import ecsd.event.entity_pubsub: PubSub;
	import ecsd.universe: Universe, findUniverse;
	
	private alias This = typeof(this);
	private static immutable invalidMessage = "Use of Entity handle after associated entity freed";
	
	private EntityID _id;
	private Universe _uni;
	
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
	
	/// Returns whether entity is `valid`.
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
		Returns whether this handle is valid, i.e. it is not default-constructed and the wrapped
		entity is alive.
	+/
	bool valid() const
	{
		return _uni !is null && _uni.isEntityAlive(_id);
	}
	
	/// Returns whether this entity is `Spawned`.
	bool spawned() const
	in(valid, invalidMessage)
	{
		return has!Spawned;
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
		Adds `Component` to this entity if it does not yet have it, otherwise overwrites the existing
		component.
		
		Shortcut for `ecsd.storage.Storage.overwrite`.
	+/
	Component* overwrite(Component)(Component inst)
	in(valid, invalidMessage)
	{
		return _uni.getStorage!Component.overwrite(_id, inst);
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
	
	/++
		Spawn/despawn this entity (by toggling `Spawned` marker.)
	+/
	void spawn()
	{
		add!Spawned;
	}
	
	/// ditto
	void despawn()
	{
		remove!Spawned;
	}
	
	/++
		Shortcuts to methods on this entity's `ecsd.event.entity_pubsub.PubSub`, doing nothing if this
		entity has no `PubSub` component.
	+/
	void delegate(Entity, ref Event) subscribe(Event)(void delegate(Entity, ref Event) fn, int priority = 0)
	if(isEvent!Event)
	{
		if(auto pubsub = tryGet!PubSub)
			return pubsub.subscribe(fn, priority);
		return null;
	}
	
	/// ditto
	void delegate(Entity, ref Event) subscribe(Event)(void function(Entity, ref Event) fn, int priority = 0)
	if(isEvent!Event)
	{
		if(auto pubsub = tryGet!PubSub)
			return pubsub.subscribe(fn, priority);
		return null;
	}
	
	/// ditto
	void unsubscribe(Event)(void delegate(Entity, ref Event) fn)
	if(isEvent!Event)
	{
		if(auto pubsub = tryGet!PubSub)
			pubsub.unsubscribe(fn);
	}
	
	/// ditto
	void unsubscribe(Event)(void function(Entity, ref Event) fn)
	if(isEvent!Event)
	{
		if(auto pubsub = tryGet!PubSub)
			pubsub.unsubscribe(fn);
	}
	
	/// ditto
	void publish(Event)(auto ref Event ev)
	if(isEvent!Event)
	{
		if(auto pubsub = tryGet!PubSub)
			pubsub.publish(ev);
	}
	
	/// ditto
	void publish(Event)()
	if(isEvent!Event)
	{
		if(auto pubsub = tryGet!PubSub)
			pubsub.publish!Event;
	}
	
	/// Methods invoked by vibe.d's serialization framework, should not be called directly.
	@trusted EntityID toRepresentation() const
	{
		if(!valid)
			return EntityID.init;
		return _id;
	}
	
	/// ditto
	@trusted static This fromRepresentation(EntityID eid)
	{
		if(eid.serial == EntityID.Serial.max)
			return This.init;
		return This(eid);
	}
}

/++
	Marker component allowing `ecsd.cache.ComponentCache`s to filter entities that are allocated
	but not yet active.
	
	Must be manually registered, or with `ecsd.registerBuiltinComponents`.
+/
struct Spawned {}

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
