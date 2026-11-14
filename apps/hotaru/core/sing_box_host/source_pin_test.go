package main

import (
	"runtime/debug"
	"testing"
)

func TestPinnedForkRejectsLocalUnpinnedAndUnexpectedSources(t *testing.T) {
	valid := func() *debug.Module {
		return &debug.Module{Path: "github.com/sagernet/sing-box", Version: "v1.14.4", Replace: &debug.Module{Path: coreForkPath, Version: coreForkVersion, Sum: coreForkSum}}
	}
	if !validPinnedModule(valid()) {
		t.Fatal("pinned fork rejected")
	}
	for _, mutate := range []func(*debug.Module){
		func(m *debug.Module) { m.Replace = nil },
		func(m *debug.Module) { m.Version = "v1.15.0" },
		func(m *debug.Module) { m.Replace.Path = "../local" },
		func(m *debug.Module) { m.Replace.Version = "" },
		func(m *debug.Module) { m.Replace.Sum = "h1:unexpected" },
	} {
		module := valid()
		mutate(module)
		if validPinnedModule(module) {
			t.Fatal("unverified source accepted")
		}
	}
}
