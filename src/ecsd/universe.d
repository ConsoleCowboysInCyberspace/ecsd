///
module ecsd.universe;

import core.time;
import std.algorithm;
import std.exception;
import std.experimental.logger;
import std.range;
import std.traits;

import vibe.data.bson;

import ecsd.component;
import ecsd.entity;
import ecsd.event.pubsub: publish;
import ecsd.events;

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
	
	private EntityID[] freeEnts; // set of ents that have been allocated but are unused
	private EntityID[] usedEnts; // entities actively being used (alive/spawned)
	
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
		
		// serialize this component to BSON
		Bson delegate(EntityID ent) serialize;
		
		// add or overwrite this component with the given BSON representation
		void delegate(EntityID ent, Bson value) deserialize;
	}
	private StorageVtable[TypeInfo] storages;
	
	// components' typeinfos, used to elide searching through keyset of `storages` when deserializing
	private TypeInfo[string] typeInfoForQualName;
	
	// key in component BSON recording fully qualified path to component type, for looking up vtables
	private static immutable typeQualPathKey = "$ecsd_typeQualifiedPath";
	
	// max of all storages' lastInvalidated timestamps, allowing caches to skip checking each storage
	package MonoTime lastAnyInvalidated;
	
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
		typeInfoForQualName.clear;
		lastAnyInvalidated = MonoTime.init;
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
		
		enum isMarkerComponent = Component.tupleof.length == 0;
		static if(isMarkerComponent)
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
		auto storage = new StorageInst(this);
		
		static if(__traits(compiles, { enum bool x = Component.ecsdSerializable; }))
			enum isSerializable = !isMarkerComponent && Component.ecsdSerializable;
		else
			enum isSerializable = !isMarkerComponent;
		
		void register(Universe uni)
		{
			if(!uni.hasComponent!Component)
				uni.registerComponent!(Component, StorageT);
		}
		
		void remove(EntityID eid)
		in(ownsEntity(eid))
		{
			if(storage.has(eid))
				storage.remove(eid);
		}
		
		void copy(EntityID src, EntityID dest)
		in(ownsEntity(src))
		{
			if(!storage.has(src)) return;
			
			auto destUni = findUniverse(dest.uid);
			if(!destUni.hasComponent!Component) return;
			
			auto destStorage = destUni.getStorage!Component;
			auto srcVal = *storage.get(src);
			destStorage.overwrite(dest, srcVal);
		}
		
		const componentQualName = typeid(Component).name;
		Bson serialize(EntityID eid)
		in(ownsEntity(eid))
		{
			auto res = Bson(null);
			if(auto ptr = storage.tryGet(eid))
			{
				static if(!isSerializable)
					res = Bson.emptyObject;
				else
					res = serializeToBson(*ptr);
				res[typeQualPathKey] = componentQualName;
				ComponentHooks.dispatch!"Serialized"(ptr, this, eid, res);
			}
			return res;
		}
		
		void deserialize(EntityID eid, Bson bson)
		in(ownsEntity(eid))
		in(bson[typeQualPathKey] == Bson(componentQualName))
		{
			static if(!isSerializable)
				Component inst;
			else
				auto inst = bson.deserializeBson!Component;
			auto ptr = storage.overwrite(eid, inst);
			ComponentHooks.dispatch!"Deserialized"(ptr, this, eid, bson);
		}
		
		StorageVtable vtable = {
			storage,
			MonoTime.currTime,
			&register,
			&remove,
			&copy,
			&serialize,
			&deserialize,
		};
		static auto tid = typeid(Component);
		storages[tid] = vtable;
		typeInfoForQualName[tid.name] = tid;
		publish(ComponentRegistered!Component(this));
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
		publish(ComponentDeregistered!Component(this));
		static auto tid = typeid(Component);
		storages.remove(tid);
		typeInfoForQualName.remove(tid.name);
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
		publish(EntityAllocated(Entity(res)));
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
		publish(EntityFreed(Entity(ent)));
		foreach(vtable; storages.byValue)
			vtable.remove(ent);
		
		usedEnts = usedEnts.remove!(SwapStrategy.unstable)(index);
		ent.serial++;
		freeEnts ~= ent;
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
	
	/// Serializes the given entity to a BSON array of objects, one object per attached component.
	Bson serializeEntity(EntityID ent)
	{
		Bson[] result;
		result.reserve(storages.length);
		foreach(vtable; storages.byValue)
		{
			auto component = vtable.serialize(ent);
			if(!component.isNull)
				result ~= component;
		}
		return Bson(result);
	}
	
	/++
		Deserializes a set of components onto a single entity. If the entity already has any
		components in the set, they will be overwritten.
		
		Params:
		ent = destination entity
		components = BSON array of component objects, as returned from `serializeEntity`
	+/
	void deserializeEntity(EntityID ent, Bson components)
	in(components.type == Bson.Type.array, "Universe.deserializeEntity expected BSON array")
	{
		foreach(component; components)
		{
			const typePathBS = component[typeQualPathKey];
			assert(
				typePathBS.type == Bson.Type.string,
				"Malformed component BSON: no/wrong type of typeQualifiedPath key\nComponent's BSON: " ~
				component.toJson.toPrettyString
			);
			const typePath = typePathBS.get!string;
			
			auto ptr = typePath in typeInfoForQualName;
			if(ptr is null)
			{
				debug warningf(
					"Component type `%s` cannot be deserialized, it has not been registered to universe %d",
					typePath,
					id,
				);
				continue;
			}
			
			storages[*ptr].deserialize(ent, component);
		}
	}
	
	/// Serializes all `activeEntities` in this universe to a BSON array.
	Bson serialize()
	{
		Bson[] result;
		result.reserve(activeEntities.length);
		foreach(ent; this)
			result ~= serializeEntity(ent);
		return Bson(result);
	}
	
	/++
		Allocates new entities and populates them with deserialized components.
		
		Params:
		entities = BSON array of arrays, outer arrays corresponding to a single entity, inner arrays
		containing component objects as returned from `serializeEntity`
	+/
	void deserialize(Bson entities)
	in(entities.type == Bson.Type.array, "Universe.deserialize expected BSON array")
	{
		foreach(components; entities)
		{
			auto ent = allocEntity;
			deserializeEntity(ent, components);
		}
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

unittest
{
	import vibe.data.serialization;
	
	auto uni = allocUniverse;
	scope(exit) freeUniverse(uni);
	
	static struct C1
	{
		int x;
	}
	uni.registerComponent!C1;
	
	static struct C2
	{
		string x;
	}
	uni.registerComponent!C2;
	
	static struct C3 {}
	uni.registerComponent!C3;
	
	static struct C4
	{
		@ignore bool deserialized;
		
		void onComponentSerialized(Universe, EntityID, ref Bson destBson)
		{
			destBson["foo"] = Bson(42);
		}
		
		void onComponentDeserialized(Universe, EntityID, Bson bson)
		{
			assert(bson["foo"] == Bson(42));
			deserialized = true;
		}
	}
	uni.registerComponent!C4;
	
	auto e1 = Entity(uni.allocEntity);
	e1.add(C1(42));
	e1.add(C2("foo"));
	e1.add!C3;
	e1.add!C4;
	
	auto e2 = Entity(uni.allocEntity);
	uni.deserializeEntity(e2, uni.serializeEntity(e1));
	assert(e2.has!C1);
	assert(*e2.get!C1 == C1(42));
	assert(e2.has!C2);
	assert(*e2.get!C2 == C2("foo"));
	assert(e2.has!C3);
	assert(e2.has!C4);
	assert(e2.get!C4.deserialized);
	
	auto uni2 = uni.dup;
	scope(exit) freeUniverse(uni2);
	uni2.destroyAllEntities; // duping only registered components
	
	uni2.deserialize(uni.serialize);
	assert(uni2.activeEntities.length == 2);
	foreach(ent; uni2)
	{
		assert(ent.has!C1);
		assert(*ent.get!C1 == C1(42));
		assert(ent.has!C2);
		assert(*ent.get!C2 == C2("foo"));
		assert(ent.has!C3);
		assert(ent.has!C4);
		assert(ent.get!C4.deserialized);
	}
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
	publish(UniverseAllocated(res));
	return res;
}

/// Destroys the given universe, and in turn all its entities.
void freeUniverse(Universe uni)
{
	assert(!uni.free);
	publish(UniverseFreed(uni));
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
