module ecsd.event;

package(ecsd):

bool isEvent(T)()
{
	enum errPreamble = "Event type " ~ T.stringof ~ " must ";
	static assert(is(T == struct), errPreamble ~ "be a struct");
	static assert(__traits(isPOD, T), errPreamble ~ "not have copy ctors/dtors");
	static assert(__traits(compiles, { T x; }), errPreamble ~ "have a default constructor");
	
	return true;
}
