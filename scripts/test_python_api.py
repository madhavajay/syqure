#!/usr/bin/env python3
"""Test script for syqure Python API - validates notebook examples work."""

import sys
import os

def test_import():
    """Test that syqure can be imported."""
    print("=== Test: Import ===")
    import syqure
    print(f"Syqure version: {syqure.version()}")
    print(f"Module doc: {syqure.__doc__}")
    assert syqure.version(), "version() should return a string"
    print("PASSED\n")

def test_info():
    """Test that info() returns expected fields."""
    print("=== Test: Info ===")
    import syqure
    info = syqure.info()
    print(f"Info keys: {list(info.keys())}")
    assert 'version' in info, "info should have 'version'"
    assert 'target' in info, "info should have 'target'"
    assert 'codon_path' in info, "info should have 'codon_path'"
    print(f"Codon path: {info.get('codon_path')}")
    print("PASSED\n")

def test_compile_and_run():
    """Test that compile_and_run works."""
    print("=== Test: compile_and_run ===")
    import syqure

    # Create test file
    test_code = 'print("Hello from test!")'
    test_file = '/tmp/syqure_test.codon'
    with open(test_file, 'w') as f:
        f.write(test_code)

    # Run it
    print(f"Running {test_file}...")
    syqure.compile_and_run(test_file)
    print("PASSED (output should appear above or in terminal)\n")

def test_compile_options():
    """Test CompileOptions."""
    print("=== Test: CompileOptions ===")
    import syqure

    opts = syqure.CompileOptions(
        release=True,
        run_after_build=True,
    )
    print(f"release: {opts.release}")
    print(f"run_after_build: {opts.run_after_build}")

    # Run with options
    test_file = '/tmp/syqure_test.codon'
    syqure.compile_and_run(test_file, opts)
    print("PASSED\n")

def test_syqure_class():
    """Test Syqure class."""
    print("=== Test: Syqure class ===")
    import syqure

    # Default instance
    compiler = syqure.Syqure.default()
    print("Created default Syqure instance")

    # Custom options instance
    opts = syqure.CompileOptions(release=False)
    compiler = syqure.Syqure(opts)
    print("Created Syqure instance with custom opts")

    # Run
    test_file = '/tmp/syqure_test.codon'
    compiler.compile_and_run(test_file)
    print("PASSED\n")

def main():
    print("=" * 50)
    print("Syqure Python API Tests")
    print("=" * 50 + "\n")

    tests = [
        test_import,
        test_info,
        test_compile_and_run,
        test_compile_options,
        test_syqure_class,
    ]

    passed = 0
    failed = 0

    for test in tests:
        try:
            test()
            passed += 1
        except Exception as e:
            print(f"FAILED: {e}\n")
            failed += 1

    print("=" * 50)
    print(f"Results: {passed} passed, {failed} failed")
    print("=" * 50)

    return 0 if failed == 0 else 1

if __name__ == "__main__":
    sys.exit(main())
