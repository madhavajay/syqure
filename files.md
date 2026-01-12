# File-Based Transport for Sequre MPC

This document explains how TCP network connections in Sequre can be proxied through files, enabling MPC computation across machines that communicate via file synchronization (e.g., SyftBox) rather than direct network connections.

## Overview

Sequre's MPC protocol requires bidirectional communication between computing parties (CP0, CP1, CP2). Normally this happens over TCP sockets. The **sbproxy** component intercepts these TCP connections and converts them to file-based message passing, allowing parties to communicate through a shared filesystem.

```
┌─────────────┐     TCP      ┌───────────────┐     Files     ┌───────────────┐     TCP      ┌─────────────┐
│  Sequre-0   │◄────────────►│   sbproxy-0   │◄─────────────►│   sbproxy-1   │◄────────────►│  Sequre-1   │
│    (CP0)    │   localhost  │               │   filesystem  │               │   localhost  │    (CP1)    │
└─────────────┘              └───────────────┘               └───────────────┘              └─────────────┘
```

## Architecture

### Components

1. **Sequre Process** - The MPC computation running Codon code with the Sequre plugin
2. **sbproxy** - A Rust-based TCP-to-file proxy (one instance per party)
3. **Message Directory** - Filesystem directory structure for message passing

### Connection Model

Sequre uses a deterministic connection rule: **lower PID listens, higher PID connects**.

| Channel | Listener | Connector |
|---------|----------|-----------|
| CP0 ↔ CP1 | CP0 | CP1 |
| CP0 ↔ CP2 | CP0 | CP2 |
| CP1 ↔ CP2 | CP1 | CP2 |

sbproxy inverts this relationship on its side:
- When Sequre **listens**, sbproxy **connects** to Sequre
- When Sequre **connects**, sbproxy **listens** for Sequre

This allows sbproxy to sit transparently between Sequre and the network.

## Message Flow

### Outgoing Message (Sequre → File)

```
1. Sequre sends data over TCP socket
2. sbproxy reads: [8-byte length prefix][message data]
3. sbproxy assigns sequential message ID
4. sbproxy writes to: {data_dir}/{from_pid}_to_{to_pid}/{seq:08d}.msg
5. sbproxy creates marker: {data_dir}/{from_pid}_to_{to_pid}/{seq:08d}.ready
```

### Incoming Message (File → Sequre)

```
1. sbproxy polls for .ready file (every 10ms by default)
2. When .ready appears, reads corresponding .msg file
3. Extracts [8-byte length prefix][message data]
4. Writes to TCP socket connected to Sequre
5. Deletes both .msg and .ready files
```

### File Format

Each message file contains:
```
┌────────────────────┬─────────────────────────┐
│  8 bytes (i64)     │  N bytes                │
│  message length    │  message data           │
└────────────────────┴─────────────────────────┘
```

The `.ready` marker file is empty - its existence signals the message is complete.

## Directory Structure

```
sandbox/mpc_messages/
├── 0_to_1/          # Messages from CP0 to CP1
│   ├── 00000000.msg
│   ├── 00000000.ready
│   ├── 00000001.msg
│   └── 00000001.ready
├── 0_to_2/          # Messages from CP0 to CP2
├── 1_to_0/          # Messages from CP1 to CP0
├── 1_to_2/          # Messages from CP1 to CP2
├── 2_to_0/          # Messages from CP2 to CP0
└── 2_to_1/          # Messages from CP2 to CP1
```

## Port Configuration

Each party uses a separate port base to avoid conflicts when testing locally:

| Party | Port Base | Listens On | Connects To |
|-------|-----------|------------|-------------|
| CP0   | 8000      | 8001, 8002 | -           |
| CP1   | 9000      | 9003       | 9001        |
| CP2   | 10000     | -          | 10002, 10003|

Port calculation formula:
```
port = base_port + (min_pid * N - min_pid * (min_pid + 1) / 2) + (max_pid - min_pid)
```

Where N = number of parties (3).

## Running Locally

The `syqure.sh` script orchestrates the entire system:

```bash
./syqure.sh run example/distributed_sum.codon
```

This:
1. Creates the sandbox directory structure
2. Launches 3 sbproxy instances
3. Launches 3 Sequre processes with appropriate port configurations
4. Monitors message flow
5. Cleans up on exit

### Manual Execution

Start sbproxy instances:
```bash
sbproxy --pid 0 --parties 3 --data-dir ./sandbox/mpc_messages \
        --base-port 8000 --sequre-base-port 8000

sbproxy --pid 1 --parties 3 --data-dir ./sandbox/mpc_messages \
        --base-port 9000 --sequre-base-port 9000

sbproxy --pid 2 --parties 3 --data-dir ./sandbox/mpc_messages \
        --base-port 10000 --sequre-base-port 10000
```

Start Sequre processes:
```bash
SEQURE_PORT_BASE=8000 SEQURE_CP_IPS=127.0.0.1,127.0.0.1,127.0.0.1 \
    ./sequre.sh example/distributed_sum.codon 0

SEQURE_PORT_BASE=9000 SEQURE_CP_IPS=127.0.0.1,127.0.0.1,127.0.0.1 \
    ./sequre.sh example/distributed_sum.codon 1

SEQURE_PORT_BASE=10000 SEQURE_CP_IPS=127.0.0.1,127.0.0.1,127.0.0.1 \
    ./sequre.sh example/distributed_sum.codon 2
```

## Distributed Deployment (SyftBox)

For actual distributed deployment across machines:

```
Machine A (CP0)                    Machine B (CP1)                    Machine C (CP2)
┌─────────────────┐                ┌─────────────────┐                ┌─────────────────┐
│ Sequre-0        │                │ Sequre-1        │                │ Sequre-2        │
│     ↕ TCP       │                │     ↕ TCP       │                │     ↕ TCP       │
│ sbproxy-0       │                │ sbproxy-1       │                │ sbproxy-2       │
│     ↕ Files     │                │     ↕ Files     │                │     ↕ Files     │
│ /shared/mpc/    │◄───SyftBox───►│ /shared/mpc/    │◄───SyftBox───►│ /shared/mpc/    │
└─────────────────┘    Sync        └─────────────────┘    Sync        └─────────────────┘
```

Each machine runs:
```bash
sbproxy --pid <party_id> --parties 3 --data-dir /shared/mpc_messages \
        --base-port <port> --sequre-base-port <port>

SEQURE_PORT_BASE=<port> ./sequre.sh script.codon <party_id>
```

The `/shared/mpc_messages` directory is synchronized by SyftBox across all machines.

## Platform Considerations

### Linux vs macOS

The socket structures differ between platforms:

**Linux `sockaddr_in`:**
```
sin_family: u16
sin_port: u16
sin_addr: u32
sin_zero: u64
```

**macOS `sockaddr_in`:**
```
sin_len: u8
sin_family: u8
sin_port: u16
sin_addr: u32
sin_zero: u64
```

The `sequre/stdlib/sequre/types/builtin.codon` file must match the target platform.

### GMP Library Path

Set via environment variable or defaults:
```bash
export SEQURE_GMP_PATH=/usr/lib/libgmp.so  # Linux
export SEQURE_GMP_PATH=/opt/homebrew/opt/gmp/lib/libgmp.dylib  # macOS
```

## Troubleshooting

### "Connection refused" during startup
Normal - sbproxy retries while waiting for Sequre to finish compiling (~15-25 seconds).

### "Failed to bind to port"
Stale processes from previous run. Kill them:
```bash
pkill -9 -f sbproxy
pkill -9 -f "codon run"
```

### "Address family not supported"
Socket structure mismatch - check `sockaddr_in` definition matches your platform.

### "undefined symbol" when loading libsequre.so
ABI mismatch - rebuild libsequre.so with the same compiler (clang) used for codon:
```bash
cd sequre && rm -rf build && mkdir build && cd build
cmake -DCODON_PATH=$HOME/.codon -DCMAKE_CXX_COMPILER=clang++ ..
make -j$(nproc)
```

## Key Files

| File | Purpose |
|------|---------|
| `syqure.sh` | Orchestration script for local testing |
| `sbproxy/src/main.rs` | TCP-to-file proxy implementation |
| `sequre.sh` | Wrapper to run Codon with Sequre plugin |
| `sequre/stdlib/sequre/settings.codon` | Port and network configuration |
| `sequre/stdlib/sequre/types/builtin.codon` | Socket structure definitions |
| `sequre/stdlib/sequre/mpc/comms.codon` | MPC communication layer |

## Alternative: Native Codon Implementation

The sbproxy approach works but requires running an external Rust process. An alternative is implementing file transport directly in Codon.

### Why This Works Without Recompiling

Codon's architecture separates:

- **C++ Plugin (libsequre.so)** - Pre-compiled IR passes for MPC/MHE optimizations
- **Codon stdlib (.codon files)** - Compiled fresh each time you run a script

The network/transport layer is entirely in `.codon` files, not in the C++ plugin. This means we can swap TCP for file-based transport by modifying Codon source files—**no recompilation of libsequre.so needed**.

### Implementation Approach

Create a file-based socket implementation with the same interface:

```
sequre/stdlib/sequre/network/
├── socket.codon          # Current TCP implementation
├── file_socket.codon     # New file-based implementation (same interface)
```

The `file_socket.codon` would implement `CSocket` using files instead of TCP:

```python
# file_socket.codon
class CSocket:
    channel_dir: str
    msg_counter: int

    def __init__(self, ip_address: str = '', port: str = '', ...):
        # Convert port/IP to channel directory path
        self.channel_dir = f"{base_dir}/{from_pid}_to_{to_pid}"
        self.msg_counter = 0

    def send(self, data: ptr[byte], length: int):
        # Write message file
        msg_path = f"{self.channel_dir}/{self.msg_counter:08d}.msg"
        ready_path = f"{self.channel_dir}/{self.msg_counter:08d}.ready"
        write_file(msg_path, data, length)
        touch(ready_path)  # Atomic marker
        self.msg_counter += 1

    def recv(self, buffer: ptr[byte], length: int) -> int:
        # Poll for .ready file, then read .msg
        while not exists(ready_path):
            sleep_ms(10)
        data = read_file(msg_path)
        delete(msg_path, ready_path)
        return len(data)
```

### Switching Transports via Environment Variable

Add transport selection in the network module:

```python
# sequre/stdlib/sequre/network/__init__.codon
import os

if os.getenv("SEQURE_USE_FILES"):
    from .file_socket import CSocket
else:
    from .socket import CSocket
```

Usage:
```bash
# TCP mode (current)
./sequre.sh script.codon 0

# File mode (no sbproxy needed)
SEQURE_USE_FILES=1 SEQURE_FILE_DIR=/shared/mpc ./sequre.sh script.codon 0
```

### Comparison

| Approach | Pros | Cons |
|----------|------|------|
| **sbproxy (current)** | No Sequre changes, works today | Extra process, TCP overhead |
| **Native Codon** | Single binary, no proxy | Requires implementing file_socket.codon |
| **C++ IR Pass** | Maximum optimization potential | Requires recompiling libsequre.so |

The native Codon approach is the sweet spot—simpler than sbproxy at runtime, and no C++ recompilation needed when iterating on the transport layer.

## Biovault integration notes (draft)

Goal: allow pipeline steps to run Sequre MPC across multiple systems, with authoring in .codon or .py (Python-like with @sequre decorators), validate locally without executing, and submit to run on actual parties.

Observed in current repo:
- The Python package in this repo is a thin wrapper over the Rust runner; it compiles/runs Codon sources but does not provide decorator-level simulation.
- The @sequre decorator is defined in Codon's Sequre stdlib, not Python.
- Biovault pipeline steps currently run "projects" via template=dynamic-nextflow only; a new runner path would be needed for syqure.

Proposed interface directions:
1) New project template "syqure" (most consistent with Biovault today).
   - project.yaml declares script (.codon or .py), inputs/outputs, and MPC config.
   - pipeline runner dispatches by template to a syqure runner (CLI or Python bindings).
   - keeps existing pipeline validation and publish/store wiring.

2) New pipeline step kind "engine: syqure" (bypass project.yaml).
   - pipeline.yaml embeds script + inputs/outputs + MPC settings inline.
   - dedicated validator and runner in pipeline code.
   - simpler authoring, but more pipeline-specific logic.

3) Keep Nextflow template and wrap syqure inside Nextflow processes.
   - minimal Biovault code change, but heavier runtime and awkward multi-party orchestration.

4) Two-phase submit model: local validate -> remote execute.
   - Python shim captures source, calls syqure.compile(run_after_build=false) to validate.
   - "Submit" emits a run manifest consumed by parties (SyftBox/file transport).
   - pipeline step coordinates status rather than executing locally.

Suggested next step: implement option (1) for integration with current pipeline system, then layer option (4) for distributed runs.

## Design Principles

1. **Transparency** - Sequre code doesn't change; sbproxy intercepts at the network layer
2. **Reliability** - Atomic message delivery via `.ready` marker files
3. **Ordering** - Sequential message IDs ensure correct delivery order
4. **Bidirectional** - Each party pair has two directories (one per direction)
5. **Stateless** - Messages are self-contained; proxies can restart without losing state
