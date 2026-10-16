// DiffViewWindowedSuites.swift
// CalyxTests
//
// Parent of the DiffView suites that swap the global DiffLayoutSettings
// store (`_testUseSuite`) and suspend at `Task.sleep`: serialized as one
// unit so their tests never interleave (each test's settings stay its own).

import Testing

@MainActor
@Suite(.serialized)
enum DiffViewWindowedSuites {}
