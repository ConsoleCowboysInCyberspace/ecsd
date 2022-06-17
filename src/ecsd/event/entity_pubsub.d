module ecsd.event.entity_pubsub;

import ecsd.entity: EntityID, Entity;
import ecsd.event: isEvent;
import ecsd.universe;

struct PubSub
{
	private EntityID owningEnt;
	private EventHandler[][TypeInfo] handlers;
	
	void onComponentAdded(Universe, EntityID owner)
	{
		owningEnt = owner;
	}
	
	void onComponentRemoved(Universe, EntityID)
	{
		handlers.clear;
	}
	
	void subscribe(Event)(void delegate(Entity, ref Event) fn, int priority = 0)
	if(isEvent!Event)
	{
		import std.algorithm: sort;
		auto ptr = typeid(Event) in handlers;
		if(ptr is null)
			ptr = &(handlers[typeid(Event)] = []);
		*ptr ~= EventHandler(fn, priority);
		(*ptr).sort!"a.priority > b.priority";
	}
	
	void subscribe(Event)(void function(Entity, ref Event) fn, int priority = 0)
	if(isEvent!Event)
	{
		import std.functional: toDelegate;
		subscribe(toDelegate(fn), priority);
	}
	
	void publish(Event)(auto ref Event ev)
	if(isEvent!Event)
	{
		auto ent = Entity(owningEnt);
		foreach(handler; handlers[typeid(Event)])
			handler.reconstruct!Event()(ent, ev);
	}
	
	void publish(Event)()
	if(isEvent!Event)
	{
		publish(Event.init);
	}
}

private struct EventHandler
{
	// to store handlers in the component directly the delgate's type needs to be erased, so we
	// store the pointers accordingly, and enforce correctness by keying handlers on event typeid
	void* context;
	void* function_;
	
	int priority;
	
	this(Event)(void delegate(Entity, ref Event) fn, int priority)
	{
		context = fn.ptr;
		function_ = fn.funcptr;
		this.priority = priority;
	}
	
	void delegate(Entity, ref Event) reconstruct(Event)()
	{
		typeof(return) result;
		result.ptr = context;
		result.funcptr = cast(typeof(result.funcptr))function_;
		return result;
	}
}

unittest
{
	static struct Foo
	{
		int x = -1;
	}
	
	auto uni = allocUniverse;
	scope(exit) freeUniverse(uni);
	auto targetEntity = uni.allocEntity;
	
	bool calledf1, calledf2;
	void f1(Entity ent, ref Foo)
	{
		assert(ent.id == targetEntity);
		assert(!calledf1);
		assert(calledf2);
		calledf1 = true;
	}
	void f2(Entity ent, ref Foo ev)
	{
		assert(ent.id == targetEntity);
		assert(!calledf1);
		assert(!calledf2);
		calledf2 = true;
		assert(ev.x == -1 || ev.x == 1);
		ev.x = 2;
	}
	
	PubSub pubsub;
	pubsub.onComponentAdded(uni, targetEntity);
	pubsub.subscribe(&f1);
	pubsub.subscribe(&f2, 1);
	
	static struct Bar {}
	static void f3(Entity, ref Bar) { assert(false); }
	pubsub.subscribe(&f3);
	
	Foo ev = { 1 };
	pubsub.publish(ev);
	assert(calledf1);
	assert(calledf2);
	assert(ev.x == 2);
	calledf1 = calledf2 = false;
	
	pubsub.publish(Foo());
	assert(calledf1);
	assert(calledf2);
	calledf1 = calledf2 = false;
	
	pubsub.publish!Foo;
	assert(calledf1);
	assert(calledf2);
}