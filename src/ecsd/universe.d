module ecsd.universe;

import std.algorithm;
import std.exception;
import std.range;

import ecsd.entity;

final class Universe
{
	import ecsd.storage: HashStorage, IStorage, Storage, isComponent;
	
    private static EntityID.UID uidCounter;
    private EntityID.EID eidCounter;
    
	const EntityID.UID id;
    private bool free;
	
	private static struct StorageVtable
	{
		IStorage inst;
		
		// register this component type with another universe, if it doesn't already have it
		void delegate(Universe other) register;
		
		// remove this component from the given entity, if it exists
		void delegate(EntityID ent) remove;
		
		// copy this component (if it exists) onto another entity, potentially in a different universe
		void delegate(EntityID src, EntityID dest) copy;
	}
	private StorageVtable[TypeInfo] storages;
	
	private EntityID[] freeEnts;
	private EntityID[] usedEnts;
    
    private this()
    {
        assert(uidCounter < EntityID.UID.max);
        id = uidCounter++;
        free = true;
    }
	
	private void onDestroy()
	{
		destroyAllEntities();
		storages.clear;
	}
	
	bool hasComponent(Component)() const
	{
		static assert(isComponent!Component);
		return (typeid(Component) in storages) !is null;
	}
	
	void registerComponent(Component, alias StorageTpl = HashStorage)()
	in(!hasComponent!Component)
	{
		static assert(isComponent!Component);
		
		static assert(
			__traits(isTemplate, StorageTpl),
			"Must pass storage type template to registerComponent"
		);
		alias StorageInst = StorageTpl!Component;
		static assert(
			is(StorageInst: Storage!Component),
			"Storage type " ~ fullyQualifiedName!StorageTpl ~ " does not extend Storage!T"
		);
		auto inst = new StorageInst(this);
		
		void register(Universe uni)
		{
			if(!uni.hasComponent!Component)
				uni.registerComponent!(Component, StorageTpl);
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
			auto srcVal = inst.get(src);
			if(!destStorage.has(dest))
				destStorage.add(dest, srcVal);
			else
				destStorage.get(dest) = srcVal;
		}
		
		StorageVtable vtable = {
			inst,
			&register,
			&remove,
			&copy,
		};
		storages[typeid(Component)] = vtable;
	}
	
	void deregisterComponent(Component)()
	in(hasComponent!Component)
	{
		storages.remove(typeid(Component));
	}
	
	Storage!Component getStorage(Component)() inout
	in(hasComponent!Component)
	{
		return cast(typeof(return))storages[typeid(Component)].inst;
	}
	
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
	
	bool isEntityAlive(EntityID ent) const
	in(ownsEntity(ent))
	{
		// FIXME: there needs to be a distinction between entities that are alive,
		// and those that have merely been allocated
		return usedEnts.canFind(ent);
	}
	
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
	
	void freeEntity(EntityID ent)
	in(ownsEntity(ent) && isEntityAlive(ent))
	{
		const index = usedEnts.countUntil(ent);
		assert(index != -1);
		freeEntityInternal(ent, index);
	}
	
	void freeEntity(Entity ent)
	{
		freeEntity(ent.id);
	}
	
	private void freeEntityInternal(EntityID ent, size_t index)
	{
		usedEnts = usedEnts.remove!(SwapStrategy.unstable)(index);
		ent.serial++;
		freeEnts ~= ent;
		
		foreach(vtable; storages.byValue)
			vtable.remove(ent);
	}
	
	void destroyAllEntities()
	{
		foreach_reverse(i, eid; usedEnts)
			freeEntityInternal(eid, i);
	}
	
	EntityID[] activeEntities()
	{
		return usedEnts[];
	}
	
	int opApply(scope int delegate(Entity) dg)
	{
		foreach(eid; activeEntities)
			if(auto res = dg(Entity(eid, this)))
				return res;
		return 0;
	}
	
	Universe dup()
	{
		auto newUni = allocUniverse;
		
		foreach(vtable; storages.byValue)
			vtable.register(newUni);
		
		foreach(ent; this)
		{
			auto newEnt = newUni.allocEntity;
			foreach(vtable; storages.byValue)
				vtable.copy(ent.id, newEnt);
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
}

private Universe[] universes;

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

void freeUniverse(Universe uni)
{
    uni.onDestroy();
    uni.free = true;
}

Universe findUniverse(EntityID.UID uid)
{
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
