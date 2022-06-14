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
		return pair.instance;
	}
	
	override void remove(EntityID ent)
	{
		storage[ent.id].serial = EntityID.Serial.max;
	}
	
	override ref Component get(EntityID ent)
	{
		return storage[ent.id].instance;
	}
}

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
		return pair.instance;
	}
	
	override void remove(EntityID ent)
	{
		storage[ent.id].serial = EntityID.Serial.max;
	}
	
	override ref Component get(EntityID ent)
	{
		return storage[ent.id].instance;
	}
}
