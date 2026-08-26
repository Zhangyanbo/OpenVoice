# OpenVoice compatibility patch

This directory vendors `visfitness/reorderable` version 1.3.2 under its MIT license.

The upstream release declares macOS support, but its two public stack source files also
contain iOS-only `#Preview` examples that reference `UIColor`. OpenVoice wraps only those
example blocks in `#if os(iOS)` so the package builds on macOS. The reorder implementation
is otherwise unchanged.
