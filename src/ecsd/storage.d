module ecsd.storage;

import ecsd.entity: EntityID;

package bool isComponent(T)()
{
	enum errPreamble = "Component type " ~ T.stringof ~ " must ";
	static assert(
		is(T == struct),
		errPreamble ~ "be a struct"
	);
	static assert(
		__traits(isPOD, T),
		errPreamble ~ "not have copy ctors/destructors"
	);
	static assert(
		__traits(compiles, { T x; }),
		errPreamble ~ "have a default constructor"
	);
	static assert(
		__traits(compiles, { T x; x = T.init; }),
		errPreamble ~ "be reassignable"
	);
	
	return true;
}

package interface IStorage {}

/// Base class for component storage implementations.
abstract class Storage(Component): IStorage
{
	private import std.string: format;
	protected import ecsd.universe: Universe;
	
	static assert(isComponent!Component);
	
	private enum componentName = Component.stringof;
	
	/++
		Pairing of an entity serial number and component instance.
		
		Storage implementations must track entity serial numbers to enforce correctness. The serial
		can also be used as a sentinel (by setting it to `-1`) to guard memory reuse.
	+/
	protected static struct Pair
	{
		EntityID.Serial serial;
		Component instance;
	}
	
	/// The universe that owns this storage instance.
	protected Universe universe;
	
	invariant(universe !is null);
	
	/++
		Storage constructor. User code should $(B never) call this directly, only ever within a
		storage implementation's constructor.
	+/
	this(Universe uni)
	{
		universe = uni;
	}
	
	/++
		These must be called in the implementation whenever a component is added to/removed from
		an entity.
		
		They fire optional hook methods in the component type, allowing components to get at their
		owning universe and entity, and perhaps other nontrivial behaviors such as
		acquiring/releasing resources.
	+/
	protected void runAddHooks(EntityID ent, Component* inst)
	{
		static if(__traits(compiles, { Component x; x.onComponentAdded(universe, ent); }))
			inst.onComponentAdded(universe, ent);
		else static if(__traits(hasMember, inst, "onComponentAdded"))
			static assert(false,
				Component.stringof ~
				".onComponentAdded does not match the expected signature " ~
				"(`void onComponentAdded(Universe, EntityID)`) and will not be called"
			);
	}
	
	/// ditto
	protected void runRemoveHooks(EntityID ent, Component* inst)
	{
		static if(__traits(compiles, { Component x; x.onComponentRemoved(universe, ent); }))
			inst.onComponentRemoved(universe, ent);
		else static if(__traits(hasMember, inst, "onComponentRemoved"))
			static assert(false,
				Component.stringof ~
				".onComponentRemoved does not match the expected signature " ~
				"(`void onComponentRemoved(Universe, EntityID)`) and will not be called"
			);
	}
	
	/// Returns whether the associated component type exists on the given entity.
	abstract bool has(EntityID ent)
	in(
		universe.ownsEntity(ent),
		"Entity passed to %s storage which belongs to different universe".format(
			componentName,
		)
	);
	
	/++
		Attaches the provided component instance to the given entity.
		
		Returns: reference to the stored instance
	+/
	abstract ref Component add(EntityID ent, Component inst)
	in(
		!has(ent),
		"Attempt to add %s to an entity that already has it".format(
			componentName,
		)
	);
	
	/// Removes the associated component type from the given entity.
	abstract void remove(EntityID ent)
	in(
		has(ent),
		"Attempt to remove %s from an entity that does not have it".format(
			componentName,
		)
	);
	
	/// Returns a reference to the associated component type on the given entity.
	abstract ref Component get(EntityID ent)
	in(
		has(ent),
		"Attempt to get %s from an entity that does not have it".format(
			componentName,
		)
	);
}

/++
	Runs tests upon the given storage implementation, when building with unittests.
	
	Examples:
	------
	final class MyStorage(Component): Storage!Component { /* ... */ }
	static assert(runStorageTests!MyStorage);
	------
+/
version(unittest)
bool runStorageTests(alias Storage)()
{
	import ecsd.universe;
	
	static struct Foo
	{
		bool added;
		bool removed;
		
		void onComponentAdded(Universe, EntityID)
		{
			added = true;
		}
		
		void onComponentRemoved(Universe, EntityID)
		{
			removed = true;
		}
	}
	
	auto uni = new Universe(null);
	auto ent = uni.allocEntity;
	auto storage = new Storage!Foo(uni);
	
	assert(!storage.has(ent));
	
	auto inst = &storage.add(ent, Foo.init);
	assert(storage.has(ent));
	assert(inst.added);
	assert(!inst.removed);
	
	assert(&storage.get(ent) == inst);
	
	storage.remove(ent);
	assert(!storage.has(ent));
	assert(inst.removed);
	
	return true;
}
else
bool runStorageTests(alias Storage)() { return true; }

/++
	Storage implementation backed by a plain array, indexed by entity id.
	
	Can be very memory expensive, as the length of the array will be the largest entity id that has
	an instance of the associated component. However component lookups (all operations really) are
	constant time, and so for components which all (or most) entities have this may yield superior
	performance.
+/
final class FlatStorage(Component): Storage!Component
{
	private Pair[] storage;
	
	this(Universe uni) { super(uni); }
	
	override bool has(EntityID ent)
	{
		return storage.length > ent.id && storage[ent.id].serial == ent.serial;
	}
	
	override ref Component add(EntityID ent, Component inst)
	{
		if(storage.length <= ent.id)
			storage.length = ent.id + 1;
		
		Pair* pair = &storage[ent.id];
		pair.serial = ent.serial;
		pair.instance = inst;
		runAddHooks(ent, &pair.instance);
		return pair.instance;
	}
	
	override void remove(EntityID ent)
	{
		auto ptr = &storage[ent.id];
		runRemoveHooks(ent, &ptr.instance);
		ptr.serial = EntityID.Serial.max;
	}
	
	override ref Component get(EntityID ent)
	{
		return storage[ent.id].instance;
	}
}
static assert(runStorageTests!FlatStorage);

/++
	Storage implementation backed by a hashmap.
	
	Offers good balance between memory usage and lookup speed. As such, this is currently the
	default storage type used for non-empty components.
+/
final class HashStorage(Component): Storage!Component
{
	private Pair[EntityID.EID] storage;
	
	this(Universe uni) { super(uni); }
	
	override bool has(EntityID ent)
	{
		auto pair = ent.id in storage;
		if(pair is null) return false;
		return pair.serial == ent.serial;
	}
	
	override ref Component add(EntityID ent, Component inst)
	{
		auto pair = ent.id in storage;
		if(pair is null)
		{
			storage[ent.id] = Pair.init;
			storage.rehash;
			pair = &storage[ent.id];
		}
		
		pair.serial = ent.serial;
		pair.instance = inst;
		runAddHooks(ent, &pair.instance);
		return pair.instance;
	}
	
	override void remove(EntityID ent)
	{
		auto pair = ent.id in storage;
		runRemoveHooks(ent, &pair.instance);
		pair.serial = EntityID.Serial.max;
	}
	
	override ref Component get(EntityID ent)
	{
		return storage[ent.id].instance;
	}
}
static assert(runStorageTests!HashStorage);

/++
	Storage implementation backed by a bit array, optimizing for empty components
	(i.e. has no fields; marker components.)
	
	When registering such a component, this type will $(B always) be chosen as the storage type,
	ignoring any explicitly specified.
+/
final class NullStorage(Component): Storage!Component
{
	import std.bitmanip;
	
	static assert(Component.tupleof.length == 0, "NullStorage can only be used with empty structs");
	
	// instance for return value of add/get, and passing to `run*Hooks`
	private static Component dummyInstance;
	private BitArray storage;
	
	this(Universe uni) { super(uni); }
	
	override bool has(EntityID ent)
	{
		return storage.length > ent.id && storage[ent.id];
	}
	
	override ref Component add(EntityID ent, Component inst)
	{
		if(storage.length <= ent.id)
			storage.length = ent.id + 1;
		storage[ent.id] = true;
		runAddHooks(ent, &dummyInstance);
		return dummyInstance;
	}
	
	override void remove(EntityID ent)
	{
		storage[ent.id] = false;
		runRemoveHooks(ent, &dummyInstance);
	}
	
	override ref Component get(EntityID ent)
	{
		return dummyInstance;
	}
}

// rewriting `runStorageTests` to accommodate `NullStorage` is not CTFE friendly :(
unittest
{
	import ecsd.universe;
	
	static struct Foo
	{
		static bool added;
		static bool removed;
		
		void onComponentAdded(Universe, EntityID)
		{
			added = true;
		}
		
		void onComponentRemoved(Universe, EntityID)
		{
			removed = true;
		}
	}
	
	auto uni = allocUniverse;
	scope(exit) freeUniverse(uni);
	auto ent = uni.allocEntity;
	auto storage = new NullStorage!Foo(uni);
	
	assert(!storage.has(ent));
	
	storage.add(ent, Foo.init);
	assert(storage.has(ent));
	assert(Foo.added);
	assert(!Foo.removed);
	
	storage.remove(ent);
	assert(!storage.has(ent));
	assert(Foo.removed);
}
