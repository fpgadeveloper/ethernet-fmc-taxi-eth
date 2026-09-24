# Build instructions

## Source code

The source code for the reference designs is managed on this Github repository:

* [https://github.com/fpgadeveloper/ethernet-fmc-taxi-eth](https://github.com/fpgadeveloper/ethernet-fmc-taxi-eth)

The repository uses a **git submodule** for the Taxi transport library (`submodules/taxi`), so
clone it with its submodules:
```
git clone --recursive https://github.com/fpgadeveloper/ethernet-fmc-taxi-eth.git
```

If you already have a clone without the submodule (or downloaded the repository as a ZIP, which
does not include submodules), run this inside the repository before building:
```
git submodule update --init
```

The Vivado build cannot find the Taxi MAC sources without it.

## License requirements

The design uses **no separately-licensed IP**: the Ethernet MAC is the open-source Taxi core and
everything else in the block design ships with Vivado. Some target designs nevertheless target
development boards for which a Vivado license is required to generate a bitstream, because the
device is not supported by the Vivado ML Standard Edition; others can be built with the Standard
Edition **without a license**. The table of target designs in the following section contains a
column specifying which designs require a license, and which can be built without a license.

## Target designs

This repo contains designs that target the supported development boards and their
FMC connectors. The table below lists the target design name, the Ethernet ports supported by the design,
the FMC connector on which to connect the mezzanine card and the software flows that are built for it.

{% for group in data.groups %}
    {% set designs_in_group = [] %}
    {% for design in data.designs %}
        {% if design.group == group.label and design.publish %}
            {% set _ = designs_in_group.append(design.label) %}
        {% endif %}
    {% endfor %}
    {% if designs_in_group | length > 0 %}
### {{ group.name }} designs

| Target board        | Target design     | Ports   | FMC Slot    | Standalone<br> Echo Server | Yocto | Vivado<br> Edition |
|---------------------|-------------------|---------|-------------|-----|-----|-----|
{% for design in data.designs %}{% if design.group == group.label and design.publish %}| [{{ design.board }}]({{ design.link }}) | `{{ design.label }}` | {{ design.lanes | length }}x | {{ design.connector }} | {% if design.baremetal %} ✅ {% else %} ❌ {% endif %} | {% if design.yocto %} ✅ {% else %} ❌ {% endif %} | {{ "Enterprise" if design.license else "Standard 🆓" }} |
{% endif %}{% endfor %}
{% endif %}
{% endfor %}

Notes:

1. The Vivado Edition column indicates which designs are supported by the Vivado *Standard* Edition, the
   FREE edition which can be used without a license. Vivado *Enterprise* Edition requires
   a license however a 30-day evaluation license is available from the AMD Xilinx Licensing site.
   
## Cross-platform build runner

All builds are driven by the `build.py` runner at the root of the repository,
on **both Windows and Linux** — the build instructions are the same for the
two operating systems. Each command builds whatever it depends on
automatically, skips anything that is already built, and locates the AMD
tools itself, so there is no need to source the settings scripts beforehand.

On Linux and on Windows (git bash), commands are run with the `build.sh`
shim, which finds a suitable Python 3 automatically (including the
interpreter bundled with the AMD tools). Windows users who prefer not to
use git bash can run the same commands from Command Prompt or PowerShell
using `build.bat` instead — the commands and arguments are otherwise
identical, for example `build.bat xsa --target <target>`.

This repository uses git submodules: clone it with `--recurse-submodules`,
or run `git submodule update --init` in an existing clone, before building
— the Vivado build fails without the submodule sources.

To see the available targets and the state of a build:

```
./build.sh list                       # list the targets and their attributes
./build.sh status --target <target>   # show the per-stage artifact state
./build.sh clean --target <target>    # delete a target's generated outputs
```

```{note} The embedded Linux images (Yocto) can only be built on a
native Linux machine; everything else builds on Windows too. On Windows, the
runner refuses the Linux-only stages up front and prints the exact command
to run on the Linux machine.
```

### Build Vivado project

This single command creates the Vivado project, generates the bitstream and
exports the hardware to an XSA file:

```
./build.sh xsa --target <target>
```

Valid targets are:
{% for design in data.designs if design.publish %} `{{ design.label }}`{{ ", " if not loop.last else "." }} {% endfor %}

If you want the Vivado project and block design without generating a
bitstream — for example, to explore or modify the design in the Vivado GUI —
run `./build.sh project --target <target>` instead, then open the project
from `Vivado/<target>/`.

### Build Vitis workspace

This creates the Vitis workspace and compiles the standalone application,
producing the baremetal boot file (`BOOT.BIN` or bit file, depending on the
device family). A target with a hard processor (the ZCU104) gets a `BOOT.BIN`
that an FSBL loads from the SD card; a **MicroBlaze target (the KCU105) has no
FSBL and no `BOOT.BIN`** — its boot files are the bitstream
(`taxieth.bit`) plus the application ELF (`echo_server.elf`), which are loaded
over JTAG (see [run the application](echo_server.md#run-the-application)).
The Vivado XSA is built first if it does not already exist:

```
./build.sh standalone --target <target>
```

Valid targets for the standalone application are:
{% for design in data.designs if design.baremetal and design.publish %} `{{ design.label }}`{{ ", " if not loop.last else "." }} {% endfor %}

The workspace is created in `Vitis/<target>_workspace` and the boot files
are gathered in `Vitis/boot/<target>/`.

### Build Yocto

This builds the Yocto / EDF image (AMD's Embedded Development Framework,
the announced successor to PetaLinux) using AMD's recommended
`gen-machineconf` / `parse-sdt` flow. It requires a native Linux machine
with [Google's `repo` tool](https://gerrit.googlesource.com/git-repo/) on
the `PATH`; the `xsct`/`sdtgen` tools come from Vitis, which the runner
locates and sources itself. The Vivado XSA is built first if it does not
already exist:

```
./build.sh yocto --target <target>
```

Valid targets for Yocto are:
{% for design in data.designs if design.yocto and design.publish %} `{{ design.label }}`{{ ", " if not loop.last else "." }} {% endfor %}

The first build of a target runs `repo sync` (several GB of git history)
and bitbake from scratch, so it takes a while; subsequent builds are
incremental. The output products (`BOOT.BIN`, the kernel, `boot.scr`,
`system.dtb`, `rootfs.wic.xz`) are gathered into
`Yocto/<target>/images/linux/`.

#### Yocto offline build

To build the Yocto projects offline (or simply faster), point the build at
a locally extracted AMD sstate-cache mirror.

1. Download the sstate-cache artefacts from the Xilinx downloads site and
   extract them to a single location, for example `/home/user/yocto-sstate`,
   leaving the following directory structure:
   ```
   /home/user/yocto-sstate
                          +---  aarch64       (Zynq UltraScale+ and Versal)
                          +---  arm           (Zynq-7000)
                          +---  microblaze    (PMU/PLM firmware)
                          +---  downloads
   ```
2. Create a text file called `offline.txt` in the `Yocto` directory of the
   repository containing a single line with that path, written with NO
   TRAILING FORWARD SLASH:
   ```
   /home/user/yocto-sstate
   ```

The Yocto build will then auto-detect which architecture sub-directories
are present and configure the build to use the mirror.

### Build everything

This builds everything that the target supports — the Vivado project and XSA,
the standalone application and the Yocto image — and gathers the boot images
into `bootimages/*.zip`:

```
./build.sh all --target <target>
./build.sh all --target all      # every target in the repo
```

On Windows, `all` builds everything that the host can build and reports the
Linux-only stages as `BLOCKED` rather than failing.
