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

abstract class Storage(Component): IStorage
{
	private import std.string: format;
	protected import ecsd.universe: Universe;
	
	static assert(isComponent!Component);
	
	private enum componentName = Component.stringof;
	
	protected static struct Pair
	{
		EntityID.Serial serial;
		Component instance;
	}
	
	protected Universe universe;
	
	invariant(universe !is null);
	
	this(Universe uni)
	{
		universe = uni;
	}
	
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
	
	abstract bool has(EntityID ent)
	in(
		universe.ownsEntity(ent),
		"Entity passed to %s storage which belongs to different universe".format(
			componentName,
		)
	);
	
	abstract ref Component add(EntityID ent, Component inst)
	in(
		!has(ent),
		"Attempt to add %s to an entity that already has it".format(
			componentName,
		)
	);
	
	abstract void remove(EntityID ent)
	in(
		has(ent),
		"Attempt to remove %s from an entity that does not have it".format(
			componentName,
		)
	);
	
	abstract ref Component get(EntityID ent)
	in(
		has(ent),
		"Attempt to get %s from an entity that does not have it".format(
			componentName,
		)
	);
}

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

final class FlatStorage(Component): Storage!Component
{
	Pair[] storage;
	
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

final class HashStorage(Component): Storage!Component
{
	Pair[EntityID.EID] storage;
	
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
