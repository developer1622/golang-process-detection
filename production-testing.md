# Production testing: identifying Go binaries and running Go processes

This document compares practical tools for identifying Go programs on Linux
and Windows without installing the Go compiler or Go runtime package on the
machine being inspected.

It complements the native scripts in this repository:

- [find-go-processes.sh](find-go-processes.sh) for Linux
- [find-go-processes.ps1](find-go-processes.ps1) for Windows
- [build-linux.sh](build-linux.sh) and [build-windows.ps1](build-windows.ps1)
  for the test binaries

## Executive recommendation

For a production live-process inventory, use this order:

1. gops for a ready-made cross-platform process list.
2. The native Bash/PowerShell detector when third-party deployment is not
   permitted.
3. Syft when binary/module/build metadata or SBOM output is needed.
4. goversion for lightweight file or directory scanning.
5. GoReSym or Redress when a binary is stripped or needs forensic analysis.
6. Detect-It-Easy when a malware-analysis/file-identification workstation is
   already available.

No tool can guarantee identification of every arbitrary executable. A binary
can be packed, transformed, deliberately modified, or made inaccessible by
permissions or process isolation.

## Scope and local test environment

Tests were run on:

~~~text
Ubuntu 24.04.4 LTS
Linux x86-64 under WSL2
Go 1.27.1 linux/amd64
~~~

Native Windows process execution was not available in this WSL2 session.
Windows PE cross-builds were created and inspected, and the PowerShell
procedure is documented, but the Windows live-process commands should also be
run on a native Windows host.

The local lab binaries were built with:

~~~bash
GOCACHE=/tmp/go-detection-lab-cache ./build-linux.sh
~~~

The six Linux programs print a heartbeat every three seconds:

~~~text
bin/linux/amd64/go-default
bin/linux/amd64/go-trimpath
bin/linux/amd64/go-stripped
bin/linux/amd64/go-nocgo
bin/linux/amd64/go-minimal
bin/linux/amd64/go-pie
~~~

## Results from this lab

| Tool | Local result | Best use |
| --- | --- | --- |
| find-go-processes.sh | Detected all 6 Linux processes | No-install Linux fallback |
| gops v0.3.29 | Detected all 6, including stripped/minimal | Live process inventory |
| goversion v1.2.0 | Normal worked; stripped was unknown; minimal returned no-symbol-section | File/directory version scan |
| Syft v1.54.1 | Detected normal and minimal as Go modules | SBOM and module/build inventory |
| Redress v1.2.93 | Identified Linux default/stripped/minimal and Windows stripped PE | Stripped Go binary analysis |
| GoReSym v1.7.1 | Linux default/stripped and Windows default/no-cgo worked; Windows stripped failed to locate pclntab | Detailed Go metadata recovery |
| Detect-It-Easy 3.21 | Not run successfully in this headless WSL session | General file identification and malware triage |

The tools are not interchangeable. The minimal binary contained enough
metadata for gops, Syft, Redress, and GoReSym on Linux, while goversion stopped
at no symbol section. GoReSym also failed on this particular stripped Windows
PE while Redress succeeded.

## 1. google/gops

Repository: [google/gops](https://github.com/google/gops)

gops is a Google-maintained diagnostic command that lists Go processes
currently running on the system. Its no-argument mode reports PID, PPID,
process name, Go version, and executable path.

It is the best first choice when the requirement is:

> Show me the running processes that appear to be Go programs.

It is not a Go standard-library command and should not be described as a
guaranteed official Go-team detector. It is an open-source Google project with
the process-listing behavior needed here.

### Install and verify

Pin a version for repeatable production use. The inspected host does not need
Go after the resulting binary is copied there:

~~~bash
mkdir -p "$HOME/bin"
GOBIN="$HOME/bin" CGO_ENABLED=0 \
    go install github.com/google/gops@v0.3.29

file "$HOME/bin/gops"
ldd "$HOME/bin/gops" || true
~~~

The static Linux build used in this test made ldd report not a dynamic
executable.

### Linux test

~~~bash
for exe in bin/linux/amd64/go-*; do
    "$exe" &
done

"$HOME/bin/gops"
~~~

Use an account with permission to inspect target processes. On a server that
may mean:

~~~bash
sudo "$HOME/bin/gops"
~~~

Access can still be limited by namespaces, containers, SELinux/AppArmor,
ptrace policy, or other kernel security controls.

### Windows test

Build or download a Windows executable:

~~~powershell
go install github.com/google/gops@v0.3.29
~~~

Or cross-compile from Linux:

~~~bash
GOOS=windows GOARCH=amd64 CGO_ENABLED=0 \
    go build -buildvcs=false -o gops.exe github.com/google/gops
~~~

Run from an elevated PowerShell window:

~~~powershell
.\gops.exe
~~~

The Windows PE executable was cross-compiled and verified locally, but not
executed here because this session has no native Windows process environment.

gops also supports stack, memory, and profiling commands when the target
application enables the optional gops agent. The agent is not required for the
basic process listing.

## 2. rsc/goversion

Repository: [rsc/goversion](https://github.com/rsc/goversion)

The current module is rsc.io/goversion. It scans files or directory trees and
prints the Go release used to build executables. It is not a live process
enumerator by itself.

### Install and use

~~~bash
mkdir -p "$HOME/bin"
GOBIN="$HOME/bin" go install rsc.io/goversion@v1.2.0

"$HOME/bin/goversion" bin/linux/amd64/go-default
"$HOME/bin/goversion" -m bin/linux/amd64/go-default
"$HOME/bin/goversion" -m /usr/bin
~~~

For a Windows executable, build or install a Windows target from a machine
with Go:

~~~bash
GOOS=windows GOARCH=amd64 CGO_ENABLED=0 \
    go build -buildvcs=false -o goversion.exe rsc.io/goversion
~~~

Then run goversion.exe against executable paths in PowerShell. Live Windows
process enumeration still comes from gops.exe or find-go-processes.ps1.

A Linux wrapper can pass executable paths from procfs:

~~~bash
for proc in /proc/[0-9]*; do
    pid=$(basename "$proc")
    exe="$proc/exe"
    [ -r "$exe" ] || continue
    "$HOME/bin/goversion" -m "$exe" 2>/dev/null |
        sed "s#^#$pid #"
done
~~~

This is slower and less direct than gops. It is best for file inventory.

### Lab result

goversion reported go1.27.1 and module/build metadata for the normal binary.
On the -s -w binary it reported unknown Go version but still printed build
metadata. On the minimal binary it returned no symbol section. Do not use it
as the only production detector.

## 3. Anchore Syft

Repository: [anchore/syft](https://github.com/anchore/syft)

Syft is primarily an SBOM and filesystem/container scanner, not a live process
lister. Its Go binary cataloger can report the main module, compiled Go version,
architecture, build settings, standard library, and other SBOM metadata.

### Install

Use an official release and verify checksums/signatures under your production
supply-chain policy. The tested Linux release was v1.54.1:

~~~bash
mkdir -p /tmp/syft-release
curl -fL \
  https://github.com/anchore/syft/releases/download/v1.54.1/syft_1.54.1_linux_amd64.tar.gz \
  | tar -xz -C /tmp/syft-release
~~~

For Windows, download the matching Windows archive and run syft.exe.

### Scan a binary

~~~bash
/tmp/syft-release/syft scan file:bin/linux/amd64/go-default \
    -q -o syft-json > go-default.sbom.json
~~~

Relevant output fields include:

~~~text
foundBy: go-module-binary-cataloger
language: go
goCompiledVersion: go1.27.1
mainModule: example.com/go-detection-lab
architecture: amd64
~~~

### Scan a running Linux executable

~~~bash
pid=1234
/tmp/syft-release/syft scan "file:/proc/$pid/exe" \
    --select-catalogers +go-module-binary-cataloger \
    -q -o syft-json > "pid-$pid.sbom.json"
~~~

The plus sign is intentional: current Syft syntax uses plus-cataloger-name to
add a cataloger to the default set. Scanning every PID with Syft is much more
expensive than gops or the Bash signature scan, so use it for candidates or
scheduled inventory.

### Lab result

Syft identified normal and minimal binaries as Go modules and reported
go1.27.1. On the minimal binary it also recorded an unknown because the symbol
section was absent, but the Go module/build-info cataloger still identified it.

## 4. GoReSym

Repository: [mandiant/GoReSym](https://github.com/mandiant/GoReSym)

GoReSym is a reverse-engineering and symbol-recovery tool. It can extract
compiler version, target OS/architecture, module data, functions, types,
strings, and paths from ELF and PE Go binaries.

### Build and use

~~~bash
git clone https://github.com/mandiant/GoReSym.git
cd GoReSym
go build -buildvcs=false -o GoReSym .

./GoReSym -t -d -p /path/to/go-binary > result.json
~~~

Use the Windows release executable similarly:

~~~powershell
.\GoReSym.exe -t -d -p C:\path\to\candidate.exe > result.json
~~~

### Lab result

GoReSym succeeded on Linux default and stripped binaries. It succeeded on the
Windows default and no-cgo binaries. It failed on this particular stripped
Windows test binary with:

~~~text
failed to read pclntab: failed to locate pclntab
~~~

Even a tool designed to handle stripped binaries can have format/version
specific failure cases. Keep another detector such as gops, Syft, Redress, or
the native marker scan.

## 5. Redress

Repository: [goretk/redress](https://github.com/goretk/redress)

Redress analyzes stripped Go binaries and reconstructs information from Go
runtime structures. It is useful for reverse engineering and binary triage,
not for enumerating PIDs.

### Install and use

~~~bash
mkdir -p "$HOME/bin"
GOBIN="$HOME/bin" go install github.com/goretk/redress@v1.2.93

"$HOME/bin/redress" info bin/linux/amd64/go-default
"$HOME/bin/redress" info bin/linux/amd64/go-stripped
"$HOME/bin/redress" info bin/linux/amd64/go-minimal
"$HOME/bin/redress" packages bin/linux/amd64/go-stripped
"$HOME/bin/redress" info bin/windows/amd64/go-stripped.exe
~~~

### Lab result

Redress identified Linux default, stripped, and minimal binaries, plus the
Windows stripped PE. It recovered compiler version, architecture, OS, module
or build settings, and build ID where available.

Use Redress when the question is “what can we recover from this suspicious
binary?” Use gops when the question is “which Go processes are running?”

## 6. Detect-It-Easy

Repositories:

- [Detect-It-Easy source](https://github.com/horsicq/Detect-It-Easy)
- [DIE-engine releases](https://github.com/horsicq/DIE-engine/releases)

Detect-It-Easy, commonly called DiE, is a general file-identification and
static-analysis tool. It supports PE, ELF, Mach-O, archives, packers, and
compiler/file signatures. Its command-line program is diec; die and diel are
GUI/lightweight interfaces.

It is useful on an analyst workstation, but it is not a live process enumerator
and should not be the only Go detector in a server fleet.

### Linux and Windows usage

Install a package, AppImage, or portable release from the official release
page. Then run:

~~~bash
diec bin/linux/amd64/go-default
diec bin/linux/amd64/go-stripped
diec bin/windows/amd64/go-default.exe
~~~

On Windows:

~~~powershell
.\diec.exe C:\path\to\go-default.exe
.\diec.exe C:\path\to\go-stripped.exe
~~~

### Local test status

I attempted the official Linux AppImage in this headless WSL environment, but
the release download did not complete. Therefore there is no honest local
detection result to report for DiE here. Run diec on the lab binaries on a
native desktop/server and record the exact signature output before depending
on it operationally.

## 7. Native scripts in this repository

### Linux Bash detector

~~~bash
sudo ./find-go-processes.sh
~~~

The script enumerates visible procfs entries, reads the executable path,
searches for Go's embedded build-info marker, falls back to runtime strings,
and caches results per executable. The local test detected all six lab
processes as BUILDINFO.

Advantages:

- no Go installation required;
- no third-party binary required;
- easy to audit and deploy;
- works with ELF executables and procfs.

Limitations:

- Linux-specific;
- requires procfs and permission to read executable files;
- reports likely Go identity, not full module/SBOM information;
- cannot see processes hidden by containers, PID namespaces, or policy.

### Windows PowerShell detector

~~~powershell
.\find-go-processes.ps1
~~~

The script uses Get-CimInstance Win32_Process, opens executable files in
chunks, and searches for the same marker. It is the native Windows equivalent
of the Bash fallback. Run PowerShell as Administrator for the widest process
visibility.

## 8. The Go build-info marker

The native scripts search for this byte sequence:

~~~text
ff 20 47 6f 20 62 75 69 6c 64 69 6e 66 3a
\xff Go buildinf:
~~~

It is associated with Go's debug/buildinfo support. In this lab it survived
normal builds, CGO_ENABLED=0, -trimpath, -s -w, clearing the linker build ID,
Linux PIE, and Windows PE builds.

Do not treat that observation as a universal guarantee. Older toolchains,
custom linkers, packers, binary rewriting, or deliberate removal can defeat
the marker. A byte marker is evidence, not cryptographic proof of a source
language.

## 9. Production wrapper patterns

### Linux: gops first, native fallback

~~~bash
#!/usr/bin/env bash
set -u

if command -v gops >/dev/null 2>&1; then
    exec gops
fi

exec /path/to/find-go-processes.sh
~~~

Use Syft, Redress, GoReSym, or goversion only on candidate executable paths
when additional metadata is needed.

### Windows: gops.exe first, PowerShell fallback

~~~powershell
if (Get-Command .\gops.exe -ErrorAction SilentlyContinue) {
    .\gops.exe
}
else {
    .\find-go-processes.ps1
}
~~~

For detailed inspection of a returned executable path:

~~~powershell
.\goversion.exe -m C:\path\to\candidate.exe
.\redress.exe info C:\path\to\candidate.exe
.\GoReSym.exe -t -d -p C:\path\to\candidate.exe
.\diec.exe C:\path\to\candidate.exe
~~~

## 10. Operational cautions

### Permissions

Use the least privilege that provides required visibility. Root or Administrator
may be needed for other users' processes, protected processes, or services.
Do not grant broad privileges permanently just to run a periodic scan.

### Performance

gops and the native marker scanner are suitable for frequent checks. Launching
Syft, Redress, GoReSym, or DiE for every PID can be expensive. A better design
is:

1. run a cheap process inventory;
2. identify new or changed executable paths;
3. run detailed analysis once per path;
4. cache by path, file identity, size, and hash.

### Containers and namespaces

Host scans see only processes visible in the host PID namespace and permitted
by host security policy. Container-local scans may see different PIDs and
paths. Correlate results with container-runtime or Kubernetes metadata.

### Deleted/replaced executables

Linux may show an executable ending in (deleted). Reading
/proc/PID/exe can still work while the process holds it open, even if resolving
it to an ordinary filesystem path fails. Prefer opening the procfs path directly
where possible.

### Supply chain

Pin versions, verify checksums/signatures, restrict tool sources, and record
tool versions in inventory output. Avoid installing unpinned @latest tools
directly on production hosts unless policy explicitly permits it.

## Final comparison

| Requirement | Recommended choice |
| --- | --- |
| List running Go PIDs immediately | gops |
| No third-party tool on Linux | find-go-processes.sh |
| No third-party tool on Windows | find-go-processes.ps1 |
| Go version/module metadata from files | Syft or goversion |
| Stripped-binary reverse engineering | Redress or GoReSym |
| General PE/ELF/packer triage | Detect-It-Easy |
| SBOM/fleet inventory | Syft plus process/deployment inventory |

## References

- [gops](https://github.com/google/gops)
- [goversion](https://github.com/rsc/goversion)
- [Syft](https://github.com/anchore/syft)
- [GoReSym](https://github.com/mandiant/GoReSym)
- [Redress](https://github.com/goretk/redress)
- [Detect-It-Easy](https://github.com/horsicq/Detect-It-Easy)
- [DIE-engine releases](https://github.com/horsicq/DIE-engine/releases)
- [Go debug/buildinfo package](https://pkg.go.dev/debug/buildinfo)
