# Go process detection lab

This repository is a controlled experiment for answering:

> Can a running Linux or Windows process be identified as a Go program when
> the Go compiler and Go runtime package are not installed on that machine?

It builds one small Go program in several ways, runs the binaries so they print
a heartbeat every three seconds, and provides one detector for Linux and one
detector for Windows.

The key distinction is:

- A statically linked Go binary does not need Go installed on the target host.
- The Go runtime is normally compiled into the executable itself.
- Static linking describes dependencies, not the programming language.
- Detection is signature-based identification, not an absolute proof.

## Repository contents

| File | Purpose | Run on |
| --- | --- | --- |
| 'main.go' | Test process using 'time.Tick(3 * time.Second)' | Build host |
| 'go.mod' | Go module definition | Build host |
| 'build-linux.sh' | Builds Linux and Windows target binaries | Linux |
| 'build-windows.ps1' | Builds Windows target binaries natively | Windows |
| 'find-go-processes.sh' | Scans running Linux processes | Linux with '/proc' |
| 'find-go-processes.ps1' | Scans running Windows processes | Windows PowerShell |

The detectors are separate because Linux exposes executable paths through
'/proc/<PID>/exe', while Windows exposes them through 'Win32_Process'.

## Binary variants

The build scripts produce these variants:

| Variant | What it tests |
| --- | --- |
| 'go-default' | Normal Go build |
| 'go-trimpath' | Removes local source paths from build metadata |
| 'go-stripped' | Uses '-ldflags="-s -w"' to remove symbols and DWARF data |
| 'go-nocgo' | Uses 'CGO_ENABLED=0' |
| 'go-minimal' | No cgo, trimmed paths, stripped, linker build ID cleared |
| 'go-pie' | Linux position-independent executable, when supported |
| 'go-no-buildid' | Windows comparison with the linker build ID cleared |

The Linux script normally produces six Linux variants. The PIE variant is
optional because PIE support depends on the target and Go toolchain. Windows
produces six variants because the Linux PIE mode is not used for Windows.

## Requirements

### Linux

Ubuntu/Debian example:

~~~bash
sudo apt update
sudo apt install -y golang-go binutils file
go version
~~~

The builder needs Go. The Linux detector does not need Go; it uses standard
utilities such as 'bash', 'readlink', 'grep', and optionally 'strings'.

### Windows

Install Go for Windows and use Windows PowerShell 5.1 or PowerShell 7. The
Windows detector does not need Go installed.

Run PowerShell as Administrator when possible so protected processes are more
likely to be visible. If scripts are blocked by execution policy, enable them
only for the current PowerShell process:

~~~powershell
Set-ExecutionPolicy -Scope Process Bypass
~~~

## Quick start on Linux

From the repository directory:

~~~bash
chmod +x build-linux.sh find-go-processes.sh
./build-linux.sh
~~~

The default output is:

~~~text
bin/linux/<Linux-architecture>/...
bin/windows/amd64/...
~~~

Start every Linux test binary:

~~~bash
for exe in bin/linux/$(go env GOARCH)/go-*; do
    "$exe" &
done
~~~

In another terminal, scan the running processes:

~~~bash
sudo ./find-go-processes.sh
~~~

The detector reports entries such as:

~~~text
PID      DETECTION    PROCESS                      EXECUTABLE
---      ---------    -------                      ----------
1234     BUILDINFO    go-default                   .../bin/linux/amd64/go-default
1235     BUILDINFO    go-minimal                   .../bin/linux/amd64/go-minimal

Candidates detected: 2
~~~

Stop the test processes using their printed PIDs. If they were started as
background jobs in the same shell, this is convenient:

~~~bash
jobs -pr | xargs -r kill
~~~

If your environment reports a read-only Go build cache, use a writable cache:

~~~bash
GOCACHE=/tmp/go-detection-lab-cache ./build-linux.sh
~~~

## Quick start on Windows

Open PowerShell in the repository directory:

~~~powershell
Set-ExecutionPolicy -Scope Process Bypass
.\build-windows.ps1
~~~

The default output is:

~~~text
bin\windows\amd64\...
~~~

Start one or more test processes:

~~~powershell
Start-Process .\bin\windows\amd64\go-default.exe
Start-Process .\bin\windows\amd64\go-stripped.exe
Start-Process .\bin\windows\amd64\go-minimal.exe
~~~

Run the Windows detector from an elevated PowerShell window:

~~~powershell
.\find-go-processes.ps1
~~~

It prints the PID, process name, detection type, and executable path. Stop only
the lab processes after testing:

~~~powershell
Get-CimInstance Win32_Process |
    Where-Object { $_.ExecutablePath -like "*go-detection-lab*" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId }
~~~

The Windows detector is a PowerShell script because Windows has no '/proc'.
Do not run the Bash detector in Git Bash or WSL expecting it to discover native
Windows processes; it will inspect the Linux/WSL process namespace instead.

## Architectures and cross-compilation

Go supports many OS/architecture combinations. The build scripts validate
requested targets using 'go tool dist list'.

### From Linux

By default, Linux uses the host Go architecture and Windows uses 'amd64'.
Choose other supported targets with environment variables:

~~~bash
LINUX_ARCH=arm64 WINDOWS_ARCH=arm64 ./build-linux.sh
~~~

This creates:

~~~text
bin/linux/arm64/...
bin/windows/arm64/...
~~~

Common architecture values include 'amd64', '386', 'arm', 'arm64', 'mips64le',
and 'riscv64'. The exact list depends on the installed Go release:

~~~bash
go tool dist list
~~~

Cross-compiled binaries can be inspected as files on the build host, but they
can only execute on a compatible OS and CPU architecture. For example, a
Windows/amd64 '.exe' cannot run natively on Linux, and Linux/arm64 cannot run
natively on an amd64 machine without emulation or compatible hardware.

### From Windows

The PowerShell builder accepts an architecture and output root:

~~~powershell
.\build-windows.ps1 -Architecture amd64
.\build-windows.ps1 -Architecture arm64
go tool dist list
~~~

The Windows builder creates 'bin\windows\<architecture>'. It builds Windows
targets only; use the Linux script or a Linux build environment for Linux
targets.

## Inspecting the binaries

On Linux:

~~~bash
file bin/linux/$(go env GOARCH)/*
readelf -h bin/linux/$(go env GOARCH)/go-default
ldd bin/linux/$(go env GOARCH)/go-default || true
~~~

'ldd' may report 'not a dynamic executable' for static binaries. That is not a
Go detector. The useful signature in this lab is Go's embedded build-info
header:

~~~bash
grep -a -F -- $'\xff Go buildinf:' \
    bin/linux/$(go env GOARCH)/go-minimal
~~~

With Go installed, this is also useful:

~~~bash
go version -m bin/linux/$(go env GOARCH)/go-minimal
~~~

On Windows, use the PowerShell detector or inspect PE files with tools such as
'dumpbin', 'objdump', or 'file' under a suitable environment.

## How detection works

### Linux: 'find-go-processes.sh'

For each visible '/proc/<PID>' entry, the script:

1. Resolves '/proc/<PID>/exe'.
2. Searches the executable for Go's embedded 'Go buildinf:' marker.
3. Falls back to recognizable Go runtime strings if build info is absent.
4. Caches the result per executable path.

'BUILDINFO' is the stronger signal. 'RUNTIME_HINT' is heuristic. Run with
'sudo' for the broadest visibility, although Linux security policy can still
hide or deny access to some processes.

### Windows: 'find-go-processes.ps1'

The script:

1. Queries running processes through 'Get-CimInstance Win32_Process'.
2. Obtains each process's executable path.
3. Reads executable files in chunks, including files currently in use.
4. Searches for the same Go build-info byte marker.
5. Caches results for processes using the same executable.

Windows reports 'BUILDINFO' only. Processes without a readable executable path,
or binaries whose Go metadata was deliberately removed or transformed, may not
be detected.

## Limitations and security notes

No language detector can guarantee identification of every arbitrary binary.
Detection can fail when:

- the executable is inaccessible because of permissions or security policy;
- the executable is heavily transformed or deliberately modified;
- Go build metadata and recognizable runtime data have been removed;
- the process is in a different PID namespace or isolated container;
- the process is not visible to the account running the detector.

The scripts inspect executable contents. They do not execute or modify the
processes they inspect. They identify running processes, not every Go binary
stored on disk, and they do not map Linux PIDs to Kubernetes Pods.

For production inventory, combine runtime scanning with deployment metadata:
systemd unit files, container image labels, Kubernetes workload data, package
inventories, and build/provenance records.

## Summary

- Use 'build-linux.sh' on Linux to build Linux variants and cross-compile
  Windows variants.
- Use 'build-windows.ps1' on Windows to build Windows variants natively.
- Use 'find-go-processes.sh' on Linux.
- Use 'find-go-processes.ps1' on Windows.
- A static Go executable still contains its compiled-in Go runtime.
- 'BUILDINFO' is strong practical evidence, not absolute proof.
