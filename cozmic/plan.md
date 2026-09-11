# Cozmic implementation and parity plan

Status: research draft in progress. This document will be consolidated against
an exact COSMIC Text checkout before delivery. No implementation is present.

The target is a Zig-native text engine with COSMIC Text behavioral coverage,
explicit dependency boundaries, differential tests, and independently tracked
Pango-inspired extensions. Porting only the visible Buffer/Editor API is not
sufficient: dependencies, optional features, fixtures, and failure behavior are
part of the coverage ledger.
