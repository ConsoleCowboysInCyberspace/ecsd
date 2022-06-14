module ecsd.entity;

struct EntityID
{
	alias EID = uint;
	alias UID = ushort;
	alias Serial = ushort;
	
    EID id;
    UID uid;
    Serial serial;
}

struct Entity
{
	import ecsd.universe: Universe, findUniverse;
	
	private static immutable invalidMessage = "Use of Entity handle after associated entity freed";
	
	private EntityID _id;
	private Universe _uni;
	
	invariant(_id.uid == _uni.id);
	
	@disable this();
	
	this(EntityID id)
	{
		_id = id;
		_uni = findUniverse(id.uid);
	}
	
	this(EntityID id, Universe uni)
	{
		_id = id;
		_uni = uni;
	}
	
	bool opCast(T: bool)() const
	{
		return valid;
	}
	
	EntityID id()
	{
		return _id;
	}
	
	Universe universe()
	{
		return _uni;
	}
	
	bool valid() const
	{
		return _uni !is null && _uni.isEntityAlive(_id);
	}
	
	bool has(Component)() const
	in(valid, invalidMessage)
	{
		return _uni.getStorage!Component.has(_id);
	}
	
	ref Component add(Component)(Component inst = Component.init)
	in(valid, invalidMessage)
	{
		return _uni.getStorage!Component.add(_id, inst);
	}
	
	void remove(Component)()
	in(valid, invalidMessage)
	{
		return _uni.getStorage!Component.remove(_id);
	}
	
	ref Component get(Component)()
	in(valid, invalidMessage)
	{
		return _uni.getStorage!Component.get(_id);
	}
	
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
