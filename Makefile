.PHONY: all
all:
	rebar3 do compile, dialyzer, eunit, ct --readable=false, cover

.PHONY: clean
clean:
	rm -rf _build
