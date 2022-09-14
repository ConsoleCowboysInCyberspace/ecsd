///
module ecsd.storage;

import std.traits: fullyQualifiedName;
import std.string: format;

import ecsd.component;
import ecsd.entity;
import ecsd.event.pubsub: publish;
import ecsd.events;

package interface IStorage {}

/// Base class for component storage implementations.
abstract class Storage(Component): IStorage
{
	protected import ecsd.universe: Universe;
	
	static assert(isComponent!Component);
	
	private enum componentName = fullyQualifiedName!Component;
	
	/++
		Pairing of an entity serial number and component instance.
		
		Storage implementations must track entity serial numbers to enforce correctness. The serial
		can also be used as a sentinel (with a value of `EntityID.Serial.max`) to guard memory reuse.
	+/
	protected static struct Pair
	{
		EntityID.Serial serial = EntityID.Serial.max;
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
		These methods $(B must) be called in the implementation whenever a component is added
		to/removed from an entity.
		
		They fire optional hook methods in the component type, allowing components to get at their
		owning universe and entity, and perhaps other nontrivial behaviors such as
		acquiring/releasing resources.
	+/
	protected void runAddHooks(EntityID ent, Component* inst)
	{
		publish(ComponentAdded!Component(Entity(ent), inst));
		ComponentHooks.dispatch!"ComponentAdded"(inst, universe, ent);
	}
	
	/// ditto
	protected void runRemoveHooks(EntityID ent, Component* inst)
	{
		publish(ComponentRemoved!Component(Entity(ent), inst));
		ComponentHooks.dispatch!"ComponentRemoved"(inst, universe, ent);
	}
	
	/++
		Invalidates all `ecsd.cache.ComponentCache`s that cache the associated component. Neglecting
		to call this method as appropriate $(B will) cause undefined behavior.
		
		This method $(B must) be called upon:
		* a component being added
		* a component being removed
		* any other operation that may invalidate cached pointers, such as a `realloc`
	+/
	protected void invalidateCaches()
	{
		universe.onStorageInvalidated(typeid(Component));
	}
	
	/// Returns whether the associated component exists on the given entity.
	final bool has(EntityID ent)
	in(
		universe.ownsEntity(ent),
		"Entity passed to %s storage which belongs to different universe".format(
			componentName,
		)
	)
	{
		return internal_has(ent);
	}
	
	/++
		Internal implementation of `has`.
		
		The virtual methods are separated to allow this base class to enforce invariants for all
		storage implementations, largely working around current shortcomings in D's contract system.
	+/
	protected abstract bool internal_has(EntityID ent);
	
	/++
		Attaches the provided component instance to the given entity.
		
		Returns: pointer to the stored instance
	+/
	final Component* add(EntityID ent, Component inst)
	in(
		!has(ent),
		"Attempt to add %s to an entity that already has it".format(
			componentName,
		)
	)
	{
		return internal_add(ent, inst);
	}
	
	/++
		Internal implementation of `add`.
		See_Also: `internal_has` for rationale.
	+/
	protected abstract Component* internal_add(EntityID ent, Component inst);
	
	/++
		Attaches component to the given entity if it does not have it, or overwrites the existing
		component if the entity already has an instance.
		
		This method should be used instead of `*componentPtr = inst` as the latter does not dispatch
		component hooks, which may lead to logic errors such as failing to unsubscribe event handlers.
		
		Returns: pointer to the stored instance
	+/
	final Component* overwrite(EntityID ent, Component inst)
	{
		if(auto ptr = tryGet(ent))
		{
			runRemoveHooks(ent, ptr);
			*ptr = inst;
			runAddHooks(ent, ptr);
			return ptr;
		}
		else
			return add(ent, inst);
	}
	
	/// Removes the associated component from the given entity.
	final void remove(EntityID ent)
	in(
		has(ent),
		"Attempt to remove %s from an entity that does not have it".format(
			componentName,
		)
	)
	{
		return internal_remove(ent);
	}
	
	/++
		Internal implementation of `remove`.
		See_Also: `internal_has` for rationale.
	+/
	protected abstract void internal_remove(EntityID ent);
	
	/++
		Returns a pointer to the associated component on the given entity.
		
		It is an error to call this with an entity that does not have any such component, therefore
		the pointer is guaranteed to not be null.
	+/
	final Component* get(EntityID ent)
	in(
		has(ent),
		"Attempt to get %s from an entity that does not have it".format(
			componentName,
		)
	)
	{
		return internal_get(ent);
	}
	
	/++
		Internal implementation of `get`.
		See_Also: `internal_has` for rationale.
	+/
	protected abstract Component* internal_get(EntityID ent);
	
	/++
		Returns a pointer to the associated component on the given entity. Unlike `get`, this will
		return null if the component does not exist.
		
		Storage implementations should override this with a more efficient strategy where possible.
	+/
	final Component* tryGet(EntityID ent)
	in(
		universe.ownsEntity(ent),
		"Entity passed to %s storage which belongs to different universe".format(
			componentName,
		)
	)
	{
		return internal_tryGet(ent);
	}
	
	/++
		Internal implementation of `tryGet`.
		See_Also: `internal_has` for rationale.
	+/
	protected Component* internal_tryGet(EntityID ent)
	{
		if(has(ent))
			return get(ent);
		return null;
	}
}

/++
	Provides a test suite for the given storage implementation.
	
	Examples:
	------
	final class MyStorage(Component): Storage!Component { /* ... */ }
	mixin storageTests!MyStorage;
	------
+/
mixin template storageTests(alias StorageT)
{
	unittest
	{
		import core.time: MonoTime;
		
		import ecsd.universe;
		import ecsd.storage: NullStorage;
		
		enum isNullStorage = __traits(isSame, StorageT, NullStorage);
		
		static struct Foo
		{
			static bool added;
			static bool removed;
			
			// prevent universe registering as NullStorage
			static if(!isNullStorage)
				int dummy;
			
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
		uni.registerComponent!(Foo, StorageT);
		auto ent = uni.allocEntity;
		auto storage = uni.getStorage!Foo;
		
		assert(!storage.has(ent));
		assert(storage.tryGet(ent) == null);
		
		auto time = MonoTime.currTime;
		assert(time >= uni.getInvalidationTimestamp(typeid(Foo)));
		
		auto inst = storage.add(ent, Foo.init);
		assert(storage.has(ent));
		assert(Foo.added);
		assert(!Foo.removed);
		assert(time < uni.getInvalidationTimestamp(typeid(Foo)));
		time = MonoTime.currTime;
		
		assert(storage.get(ent) == inst);
		assert(storage.tryGet(ent) == inst);
		
		storage.remove(ent);
		assert(!storage.has(ent));
		assert(Foo.removed);
		assert(time < uni.getInvalidationTimestamp(typeid(Foo)));
	}
}

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
	
	protected override bool internal_has(EntityID ent)
	{
		return storage.length > ent.id && storage[ent.id].serial == ent.serial;
	}
	
	protected override Component* internal_add(EntityID ent, Component inst)
	{
		if(storage.length <= ent.id)
			storage.length = ent.id + 1;
		
		Pair* pair = &storage[ent.id];
		pair.serial = ent.serial;
		pair.instance = inst;
		runAddHooks(ent, &pair.instance);
		invalidateCaches();
		return &pair.instance;
	}
	
	protected override void internal_remove(EntityID ent)
	{
		auto ptr = &storage[ent.id];
		runRemoveHooks(ent, &ptr.instance);
		invalidateCaches();
		ptr.serial = EntityID.Serial.max;
	}
	
	protected override Component* internal_get(EntityID ent)
	{
		return &storage[ent.id].instance;
	}
}
mixin storageTests!FlatStorage;

/++
	Storage implementation backed by a hashmap.
	
	Offers good balance between memory usage and lookup speed. As such, this is currently the
	default storage type used for non-empty components.
+/
final class HashStorage(Component): Storage!Component
{
	private Pair[EntityID.EID] storage;
	
	this(Universe uni) { super(uni); }
	
	protected override bool internal_has(EntityID ent)
	{
		auto pair = ent.id in storage;
		if(pair is null) return false;
		return pair.serial == ent.serial;
	}
	
	protected override Component* internal_add(EntityID ent, Component inst)
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
		invalidateCaches();
		return &pair.instance;
	}
	
	protected override void internal_remove(EntityID ent)
	{
		auto pair = ent.id in storage;
		runRemoveHooks(ent, &pair.instance);
		invalidateCaches();
		pair.serial = EntityID.Serial.max;
	}
	
	protected override Component* internal_get(EntityID ent)
	{
		return &storage[ent.id].instance;
	}
	
	protected override Component* internal_tryGet(EntityID ent)
	{
		auto pair = ent.id in storage;
		if(pair is null || pair.serial != ent.serial)
			return null;
		return &pair.instance;
	}
}
mixin storageTests!HashStorage;

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
	
	protected override bool internal_has(EntityID ent)
	{
		return storage.length > ent.id && storage[ent.id];
	}
	
	protected override Component* internal_add(EntityID ent, Component inst)
	{
		if(storage.length <= ent.id)
			storage.length = ent.id + 1;
		storage[ent.id] = true;
		runAddHooks(ent, &dummyInstance);
		invalidateCaches();
		return &dummyInstance;
	}
	
	protected override void internal_remove(EntityID ent)
	{
		storage[ent.id] = false;
		runRemoveHooks(ent, &dummyInstance);
		invalidateCaches();
	}
	
	protected override Component* internal_get(EntityID ent)
	{
		return &dummyInstance;
	}
}
mixin storageTests!NullStorage;
