# CI status (current breakages)

## Failing workflow

- Run: https://github.com/madhavajay/syqure/actions/runs/20892067474/job/60026242486
- Stage: Codon build (xeus/xeus-zmq via CPM in Codon Jupyter build).

## Error

CMake fails while configuring `xeus-zmq`:

```
CMake Error at build/_deps/xeus-zmq-src/CMakeLists.txt:199 (target_link_libraries):
  Target "xeus-zmq-static" links to:

    OpenSSL::Crypto

  but the target was not found.
```

## Notes

- CMake reports `Found OpenSSL: /usr/lib/libssl.so (found version "3.0.2")` and `Found sodium`, so the library is present, but the imported target `OpenSSL::Crypto` is not defined during xeus-zmq configure.
- `CODON_ENABLE_OPENMP` is reported as unused by CMake in this step.

## Hypothesis (to validate)

- The build is not calling `find_package(OpenSSL REQUIRED)` in the right scope before xeus-zmq tries to link, so the `OpenSSL::Crypto` target never gets created.
- Alternatively, the CI environment is missing the OpenSSL CMake config package (even though libssl is present), so the `OpenSSL::Crypto` target is not available.
