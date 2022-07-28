///
module ecsd.universe;

import core.time;
import std.algorithm;
import std.exception;
import std.range;
import std.traits;

import ecsd.entity;

/++
	A universe is a collection of components, and a grouping of entities. Entities within the same
	universe will interact, but entities of differing universes will not.
	
	Universes will typically correspond to game worlds, one per world. But differing universes may
	be used for any variety of uses, e.g. layers in a component-based user interface system.
+/
final class Universe
{
	import ecsd.storage;
	
	// global counter for universe IDs
    private static EntityID.UID uidCounter;
	
	// entity ID counter
    private EntityID.EID eidCounter;
    
	/// The id of this universe, corresponding to `ecsd.entity.EntityID.uid`.
	const EntityID.UID id;
    private bool free;
	
	private static struct StorageVtable
	{
		IStorage inst;
		
		// timestamp of last operation which may have invalidated component caches
		MonoTime lastInvalidated;
		
		// register this component type with another universe, if it doesn't already have it
		void delegate(Universe other) register;
		
		// remove this component from the given entity, if it exists
		void delegate(EntityID ent) remove;
		
		// copy this component (if it exists) onto another entity, potentially in a different universe
		void delegate(EntityID src, EntityID dest) copy;
	}
	private StorageVtable[TypeInfo] storages;
	
	// max of all storages' lastInvalidated timestamps, allowing caches to skip checking each storage
	package MonoTime lastAnyInvalidated;
	
	private EntityID[] freeEnts; // set of ents that have been allocated but are unused
	private EntityID[] usedEnts; // entities actively being used (alive/spawned)
    
    private this()
    {
        assert(uidCounter < EntityID.UID.max);
        id = uidCounter++;
        free = true;
    }
	
	// dummy constructor for CTFE tests
	package this(typeof(null))
	{
		assert(__ctfe);
		id = 0;
	}
	
	private void onDestroy()
	{
		destroyAllEntities();
		storages.clear;
	}
	
	/// Returns whether this universe has been set up to store components of the given type.
	bool hasComponent(Component)() const
	{
		static assert(isComponent!Component);
		return (typeid(Component) in storages) !is null;
	}
	
	/++
		Register the given component type to be usable with entities of this universe.
		
		If no storage implementation is specified, `ecsd.storage.HashStorage` will be used.
		
		If the component type is empty (has no fields,) `ecsd.storage.NullStorage` is $(B always)
		used, regardless of any explicitly specified type.
		
		Params:
			StorageTpl = `ecsd.storage.Storage` implementation to use for this component
	+/
	void registerComponent(Component, alias StorageTpl = HashStorage)()
	in(!hasComponent!Component, "Component " ~ fullyQualifiedName!Component ~ " has already been registered to universe")
	{
		static assert(isComponent!Component);
		
		static if(Component.tupleof.length == 0)
			alias StorageT = NullStorage;
		else
			alias StorageT = StorageTpl;
		
		static assert(
			__traits(isTemplate, StorageT),
			"Must pass storage type template to registerComponent"
		);
		alias StorageInst = StorageT!Component;
		static assert(
			is(StorageInst: Storage!Component),
			"Storage type " ~ fullyQualifiedName!StorageT ~ " does not extend Storage!T"
		);
		auto inst = new StorageInst(this);
		
		void register(Universe uni)
		{
			if(!uni.hasComponent!Component)
				uni.registerComponent!(Component, StorageT);
		}
		
		void remove(EntityID eid)
		in(ownsEntity(eid))
		{
			if(inst.has(eid))
				inst.remove(eid);
		}
		
		void copy(EntityID src, EntityID dest)
		in(ownsEntity(src))
		{
			if(!inst.has(src)) return;
			
			auto destUni = findUniverse(dest.uid);
			if(!destUni.hasComponent!Component) return;
			
			auto destStorage = destUni.getStorage!Component;
			auto srcVal = *inst.get(src);
			if(!destStorage.has(dest))
				destStorage.add(dest, srcVal);
			else
				*destStorage.get(dest) = srcVal;
		}
		
		StorageVtable vtable = {
			inst,
			MonoTime.currTime,
			&register,
			&remove,
			&copy,
		};
		storages[typeid(Component)] = vtable;
	}
	
	/++
		Remove registration of the given component type from this universe.
		
		Any entities with the component will have it implicitly removed.
	+/
	void deregisterComponent(Component)()
	in(hasComponent!Component, "Component " ~ fullyQualifiedName!Component ~ " has not been registered to universe")
	{
		// FIXME: should probably call remove for all ents
		// components' remove hooks may manage resources
		storages.remove(typeid(Component));
	}
	
	/++
		Returns the $(LREF Storage) instance that was registered to store components of the
		given type.
	+/
	Storage!Component getStorage(Component)() inout
	in(hasComponent!Component, "Component " ~ fullyQualifiedName!Component ~ " has not been registered to universe")
	{
		return cast(typeof(return))storages[typeid(Component)].inst;
	}
	
	package void onStorageInvalidated(TypeInfo component)
	in(component in storages)
	{
		lastAnyInvalidated = storages[component].lastInvalidated = MonoTime.currTime;
	}
	
	package MonoTime getInvalidationTimestamp(TypeInfo component) const
	in(component in storages)
	{
		return storages[component].lastInvalidated;
	}
	
	/// Returns whether this universe owns the given entity.
	bool ownsEntity(EntityID ent) const
	{
		bool extra = true;
		debug
		{
			// ignoring serials as a universe still owns older, dead incarnations
			alias pred = (e) => e.id == ent.id;
			extra = usedEnts.canFind!pred || freeEnts.canFind!pred;
		}
		return ent.uid == id && extra;
	}
	
	/// Returns whether the given entity is currently alive.
	bool isEntityAlive(EntityID ent) const
	in(ownsEntity(ent), "Attempt to use entity with universe that does not own it")
	{
		// FIXME: there needs to be a distinction between entities that are alive,
		// and those that have merely been allocated
		return usedEnts.canFind(ent);
	}
	
	/++
		Allocates a new entity within this universe.
	
		Returns: the `ecsd.entity.EntityID` of the new entity.
	+/
	EntityID allocEntity()
	{
		if(freeEnts.empty)
			foreach(_; 0 .. 32)
			{
				assert(eidCounter < EntityID.EID.max);
				freeEnts ~= EntityID(eidCounter++, id);
			}
		
		auto res = freeEnts.back;
		freeEnts.popBack;
		usedEnts ~= res;
		return res;
	}
	
	/// Destroys the given entity.
	void freeEntity(EntityID ent)
	in(ownsEntity(ent) && isEntityAlive(ent), "Attempt to free entity that has already been freed")
	{
		const index = usedEnts.countUntil(ent);
		assert(index != -1);
		freeEntityInternal(ent, index);
	}
	
	private void freeEntityInternal(EntityID ent, size_t index)
	{
		usedEnts = usedEnts.remove!(SwapStrategy.unstable)(index);
		ent.serial++;
		freeEnts ~= ent;
		
		foreach(vtable; storages.byValue)
			vtable.remove(ent);
	}
	
	/// Destroys all entities that are currently alive in this universe.
	void destroyAllEntities()
	{
		foreach_reverse(i, eid; usedEnts)
			freeEntityInternal(eid, i);
	}
	
	/// Returns a slice of `ecsd.entity.EntityID`s which are currently alive in this universe.
	inout(EntityID)[] activeEntities() inout
	{
		return usedEnts[];
	}
	
	/// Loop over all entities that are alive in this universe.
	int opApply(scope int delegate(Entity) dg)
	{
		foreach(eid; activeEntities)
			if(auto res = dg(Entity(eid, this)))
				return res;
		return 0;
	}
	
	/++
		Copies all components from one entity into another.
		
		Components that already exist on the target entity will be overwritten.
		
		The entity being copied into may be in a different universe, but use care as components
		that are not registered in the other universe will be silently skipped.
		
		Params:
			source = entity to copy from, must be alive and owned by this universe
			destination = entity to copy into, if unspecified a new entity is made in this universe
		
		Returns: destination entity ID
	+/
	EntityID copyEntity(EntityID source, EntityID destination)
	in(ownsEntity(source) && isEntityAlive(source), "Attempt to copy dead entity / entity from another universe")
	{
		foreach(vtable; storages.byValue)
			vtable.copy(source, destination);
		return destination;
	}

	/// ditto
	EntityID copyEntity(EntityID source)
	in(ownsEntity(source) && isEntityAlive(source), "Attempt to copy dead entity / entity from another universe")
	{
		return copyEntity(source, allocEntity);
	}
	
	/// Allocates a new universe and places into it copies of every entity in this universe.
	Universe dup()
	{
		auto newUni = allocUniverse;
		
		foreach(vtable; storages.byValue)
			vtable.register(newUni);
		
		foreach(ent; this)
		{
			auto newEnt = newUni.allocEntity;
			copyEntity(ent.id, newEnt);
		}
		
		return newUni;
	}
}

unittest
{
	auto uni = allocUniverse;
	scope(exit) freeUniverse(uni);
	
	static struct TestComponent {}
	assert(!uni.hasComponent!TestComponent);
	uni.registerComponent!TestComponent;
	assert(uni.hasComponent!TestComponent);
	assert(uni.getStorage!TestComponent);
	uni.deregisterComponent!TestComponent;
	assert(!uni.hasComponent!TestComponent);
	assertThrown!Throwable(uni.getStorage!TestComponent);
	
	auto ent = uni.allocEntity;
	assert(uni.ownsEntity(ent));
	assert(uni.isEntityAlive(ent)); // FIXME: see isEntityAlive
	uni.freeEntity(ent);
	assert(uni.ownsEntity(ent));
	assert(!uni.isEntityAlive(ent));
	
	uni.registerComponent!TestComponent;
	auto storage = uni.getStorage!TestComponent;
	ent = uni.allocEntity;
	storage.add(ent, TestComponent.init);
	auto e2 = uni.copyEntity(ent);
	assert(storage.has(e2));
}

private Universe[] universes;

/// Allocate a new universe.
Universe allocUniverse()
{
    auto uid = universes.countUntil!(u => u.free);
    if(uid == -1)
    {
        uid = universes.length;
        if(universes.length > 0)
            universes.length *= 2;
       	else
            universes.length = 4;
		
        foreach(ref ptr; universes[uid .. $])
        	ptr = new Universe();
    }
    
    auto res = universes[uid];
    res.free = false;
    return res;
}

/// Destroys the given universe, and in turn all its entities.
void freeUniverse(Universe uni)
{
	assert(!uni.free);
    uni.onDestroy();
    uni.free = true;
}

/++
	Returns a universe reference given its id.
	
	May return a universe that has been freed.
+/
Universe findUniverse(EntityID.UID uid)
{
	assert(universes.length > uid);
	return universes[uid];
}

unittest
{
    auto uni = allocUniverse;
    assert(!uni.free);
	assert(findUniverse(uni.id) is uni);
    freeUniverse(uni);
    assert(uni.free);
}
