module ecsd.event.pubsub;

import ecsd.event: isEvent;

/++
	Register the given function to be called whenever an event of the corresponding type is
	`publish`ed.
	
	Params:
		priority = dispatch order of event handlers, descending (larger priorities execute first)
+/
void subscribe(Event)(void delegate(ref Event) fn, int priority = 0)
if(isEvent!Event)
{
	import std.algorithm: sort;
	alias evs = storage!Event;
	evs ~= EventHandler!Event(fn, priority);
	evs.sort!"a.priority > b.priority";
}

/// ditto
void subscribe(Event)(void function(ref Event) fn, int priority = 0)
if(isEvent!Event)
{
	import std.functional: toDelegate;
	subscribe(fn.toDelegate, priority);
}

/++
	Immediately dispatches the given event, passing it to all registered subscribers.
+/
void publish(Event)(auto ref Event ev)
if(isEvent!Event)
{
	foreach(handler; storage!Event)
		handler.fn(ev);
}

/// ditto
void publish(Event)()
if(isEvent!Event)
{
	publish(Event.init);
}

private:

struct EventHandler(Event)
{
	void delegate(ref Event) fn;
	int priority = 0;
}

template storage(Event)
{
	EventHandler!Event[] storage;
}

unittest
{
	static struct Foo
	{
		int x = -1;
	}
	
	bool calledf1, calledf2;
	void f1(ref Foo)
	{
		assert(!calledf1);
		assert(calledf2);
		calledf1 = true;
	}
	void f2(ref Foo ev)
	{
		assert(!calledf1);
		assert(!calledf2);
		calledf2 = true;
		assert(ev.x == -1 || ev.x == 1);
		ev.x = 2;
	}
	subscribe(&f1);
	subscribe(&f2, 1);
	
	static struct Bar {}
	static void f3(ref Bar) { assert(false); }
	subscribe(&f3);
	
	Foo ev = { 1 };
	publish(ev);
	assert(calledf1);
	assert(calledf2);
	assert(ev.x == 2);
	calledf1 = calledf2 = false;
	
	publish(Foo());
	assert(calledf1);
	assert(calledf2);
	calledf1 = calledf2 = false;
	
	publish!Foo;
	assert(calledf1);
	assert(calledf2);
}
